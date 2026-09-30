// What is this module called?
module hydration;

// What does this module require to function?
import core.atomic;
import core.stdc.errno;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.json;
import std.path;
import std.string;
import std.uni;

// What other modules that we have created do we need to import?
import config;
import curlEngine;
import itemdb;
import log;
import onedrive;
import util;

// On-demand hydration state of a file item
enum HydrationState { onlineOnly, hydrated, pinned }

// Database encoding of HydrationState. NULL (null) in the database means hydrated.
enum string hydrationOnlineOnly = "O";
enum string hydrationHydrated = "H";
enum string hydrationPinned = "P";

// Error raised to FUSE callers. errnoCode: ENETUNREACH/EIO offline, ENOENT gone online, EIO other
class HydrationError : Exception {
	int errnoCode;

	this(int errnoCode, string msg, string file = __FILE__, size_t line = __LINE__) {
		super(msg, file, line);
		this.errnoCode = errnoCode;
	}
}

// Actions requested through the mount (user.onedrive.action) or the CLI
enum OnDemandAction { download, pin, unpin, free }

// A queued action for the HydrationService background worker
private struct OnDemandActionRequest {
	string driveId;
	string id;
	OnDemandAction action;
}

// Local change kinds reported by the FUSE layer for the backing directory
enum OnDemandChangeKind { changed, createDir, deleted, moved }

// A local change reported by the FUSE layer. Paths are "./a/b", relative to the backing directory
struct OnDemandLocalChange {
	OnDemandChangeKind kind;
	string path;
	string oldPath;
}

// Message sent to the main thread to wake the monitor loop: send(mainTid, OnDemandWake())
struct OnDemandWake {}

// Mutex-protected queue of local changes. Written by FUSE threads, drained by the main thread.
final class OnDemandChangeQueue {
	private Mutex queueMutex;
	private OnDemandLocalChange[] changes;

	this() {
		queueMutex = new Mutex();
	}

	void push(OnDemandLocalChange change) {
		queueMutex.lock();
		scope(exit) queueMutex.unlock();
		changes ~= change;
	}

	// Remove and return all queued changes in arrival order
	OnDemandLocalChange[] drain() {
		queueMutex.lock();
		scope(exit) queueMutex.unlock();
		OnDemandLocalChange[] result = changes;
		changes = null;
		return result;
	}
}

// Serialises every check-then-act sequence that reads backing-file presence and writes the
// DB hydration state, between the main-thread sync engine and HydrationService (FUSE threads).
// Lock order: this mutex first, then the ItemDatabase lock. Never held across network I/O.
private __gshared Mutex onDemandStateMutex;
// Open file handles per item ("driveId/id"), reported by the FUSE layer; guarded by onDemandStateMutex
private __gshared int[string] onDemandOpenHandles;

shared static this() {
	onDemandStateMutex = new Mutex();
	transientStateMutex = new Mutex();
	deferredOnlineChangeMutex = new Mutex();
	lockedUploadRetryMutex = new Mutex();
}

// Registry key of an item. Microsoft Graph reports the same drive id in different letter case
// (Issue #3336; the database stores personal drive ids lower case), so the drive id is compared
// case-insensitively: a state set from delta JSON must be found and cleared from database ids.
private string itemKey(string driveId, string id) {
	return std.uni.toLower(driveId) ~ "/" ~ id;
}

// Does the FUSE layer hold an open handle on this item?
bool onDemandItemIsOpen(string driveId, string id) {
	onDemandStateMutex.lock();
	scope(exit) onDemandStateMutex.unlock();
	return (itemKey(driveId, id) in onDemandOpenHandles) !is null;
}

// Transient sync states (user.onedrive.state: syncing, pending, error), per item
enum TransientState { none, syncing, pending, error }

private __gshared Mutex transientStateMutex;
private __gshared TransientState[string] transientStates;
private shared ulong transientStateWrites;

// Set (or with 'none' clear) the transient state of an item. Thread-safe.
void setTransientState(string driveId, string id, TransientState state) {
	transientStateMutex.lock();
	scope(exit) transientStateMutex.unlock();
	string key = itemKey(driveId, id);
	if (state == TransientState.none) {
		if (key !in transientStates) return;
		transientStates.remove(key);
	} else {
		if (auto current = key in transientStates) {
			if (*current == state) return;
		}
		transientStates[key] = state;
	}
	atomicOp!"+="(transientStateWrites, 1);
}

// Clear the transient state of an item unless it is the given state
void clearTransientStateUnless(string driveId, string id, TransientState keep) {
	transientStateMutex.lock();
	scope(exit) transientStateMutex.unlock();
	string key = itemKey(driveId, id);
	if (auto current = key in transientStates) {
		if (*current == keep) return;
		transientStates.remove(key);
		atomicOp!"+="(transientStateWrites, 1);
	}
}

TransientState transientStateOfItem(string driveId, string id) {
	transientStateMutex.lock();
	scope(exit) transientStateMutex.unlock();
	if (auto state = itemKey(driveId, id) in transientStates) return *state;
	return TransientState.none;
}

private TransientState[string] transientStatesSnapshot() {
	transientStateMutex.lock();
	scope(exit) transientStateMutex.unlock();
	return transientStates.dup;
}

// Online changes not applied because the local file was open (see recordDeferredOnlineChange)
struct DeferredOnlineChange {
	string driveId;
	string id;
	// eTag of the online version that was deferred
	string eTag;
	bool ignoreDataPreservationCheck;
}

private __gshared Mutex deferredOnlineChangeMutex;
private __gshared DeferredOnlineChange[string] deferredOnlineChanges;
private __gshared DeferredOnlineChange[] readyDeferredOnlineChanges;
// Called (on a FUSE thread) when a deferred item's last handle closes; wakes the main thread
private __gshared void delegate() deferredOnlineChangeReadyHandler;

// If the item is open locally, record that its newer online version (eTag) was not applied and
// return true; 'first' is set the first time for this item (so the caller logs once). The open
// check and the record happen under the state lock that noteClose() uses, so a close cannot fall
// between them. The item shows 'pending' until the change is applied.
bool deferOnlineChangeIfOpen(string driveId, string id, string eTag, bool ignoreDataPreservationCheck, out bool first) {
	onDemandStateMutex.lock();
	scope(exit) onDemandStateMutex.unlock();
	if ((itemKey(driveId, id) in onDemandOpenHandles) is null) return false;
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	string key = itemKey(driveId, id);
	first = (key !in deferredOnlineChanges);
	deferredOnlineChanges[key] = DeferredOnlineChange(driveId, id, eTag, ignoreDataPreservationCheck);
	setTransientState(driveId, id, TransientState.pending);
	return true;
}

// Put a deferral back (its re-evaluation could not complete); it is retried at the next sync cycle
void restoreDeferredOnlineChange(DeferredOnlineChange deferred) {
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	deferredOnlineChanges[itemKey(deferred.driveId, deferred.id)] = deferred;
}

// Queue a deferral for re-evaluation on the main thread (restart, or found closed at a sync cycle)
void queueDeferredOnlineChangeForReevaluation(string driveId, string id, string eTag) {
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	deferredOnlineChanges.remove(itemKey(driveId, id));
	readyDeferredOnlineChanges ~= DeferredOnlineChange(driveId, id, eTag, false);
	setTransientState(driveId, id, TransientState.pending);
}

// Move every deferral whose file is no longer open to the ready list (re-check at each sync cycle)
void readyClosedDeferredOnlineChanges() {
	onDemandStateMutex.lock();
	scope(exit) onDemandStateMutex.unlock();
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	string[] closed;
	foreach (key, deferred; deferredOnlineChanges) {
		if ((key in onDemandOpenHandles) is null) {
			readyDeferredOnlineChanges ~= deferred;
			closed ~= key;
		}
	}
	foreach (key; closed) deferredOnlineChanges.remove(key);
}

bool hasDeferredOnlineChange(string driveId, string id) {
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	return (itemKey(driveId, id) in deferredOnlineChanges) !is null;
}

// Forget a deferral (the change was applied or superseded)
void clearDeferredOnlineChange(string driveId, string id) {
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	deferredOnlineChanges.remove(itemKey(driveId, id));
}

// Deferred changes whose file is no longer open, for re-evaluation on the main thread
DeferredOnlineChange[] takeReadyDeferredOnlineChanges() {
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	DeferredOnlineChange[] ready = readyDeferredOnlineChanges;
	readyDeferredOnlineChanges = null;
	return ready;
}

void setDeferredOnlineChangeReadyHandler(void delegate() handler) {
	deferredOnlineChangeMutex.lock();
	scope(exit) deferredOnlineChangeMutex.unlock();
	deferredOnlineChangeReadyHandler = handler;
}

// The last handle of an item closed: hand a deferred change to the main thread
private void deferredItemClosed(string driveId, string id) {
	void delegate() handler;
	{
		deferredOnlineChangeMutex.lock();
		scope(exit) deferredOnlineChangeMutex.unlock();
		string key = itemKey(driveId, id);
		auto deferred = key in deferredOnlineChanges;
		if (deferred is null) return;
		readyDeferredOnlineChanges ~= *deferred;
		deferredOnlineChanges.remove(key);
		handler = deferredOnlineChangeReadyHandler;
	}
	if (handler !is null) handler();
}

// Uploads refused because the item is checked out or locked online, retried on a short schedule
struct LockedUploadRetry {
	string driveId;
	string id;
	string localPath;
	int attempts;
	MonoTime due;
}

private __gshared Mutex lockedUploadRetryMutex;
private __gshared LockedUploadRetry[string] lockedUploadRetries;
private immutable int[] lockedUploadRetrySeconds = [30, 60, 120];

// Record a locked-online upload refusal; schedules the next attempt (30 s, 60 s, 120 s, then the monitor interval)
void recordLockedUpload(string driveId, string id, string localPath, Duration monitorInterval) {
	lockedUploadRetryMutex.lock();
	scope(exit) lockedUploadRetryMutex.unlock();
	string key = itemKey(driveId, id);
	int attempts = 0;
	if (auto existing = key in lockedUploadRetries) attempts = existing.attempts + 1;
	Duration delay = (attempts < lockedUploadRetrySeconds.length) ? dur!"seconds"(lockedUploadRetrySeconds[attempts]) : monitorInterval;
	lockedUploadRetries[key] = LockedUploadRetry(driveId, id, localPath, attempts, MonoTime.currTime + delay);
	setTransientState(driveId, id, TransientState.pending);
}

// Number of locked-online refusals recorded for the item so far, or -1 if none is registered
int lockedUploadAttempts(string driveId, string id) {
	lockedUploadRetryMutex.lock();
	scope(exit) lockedUploadRetryMutex.unlock();
	if (auto retry = itemKey(driveId, id) in lockedUploadRetries) return retry.attempts;
	return -1;
}

// Is a retry of this item taken by takeDueLockedUploads() without a new refusal since?
bool lockedUploadRetryAwaitingResult(string driveId, string id) {
	lockedUploadRetryMutex.lock();
	scope(exit) lockedUploadRetryMutex.unlock();
	if (auto retry = itemKey(driveId, id) in lockedUploadRetries) return retry.due == MonoTime.max;
	return false;
}

bool hasLockedUploadRetry(string driveId, string id) {
	lockedUploadRetryMutex.lock();
	scope(exit) lockedUploadRetryMutex.unlock();
	return (itemKey(driveId, id) in lockedUploadRetries) !is null;
}

void clearLockedUploadRetry(string driveId, string id) {
	lockedUploadRetryMutex.lock();
	scope(exit) lockedUploadRetryMutex.unlock();
	lockedUploadRetries.remove(itemKey(driveId, id));
}

// Retries that are due now. They stay registered (not due again) until the attempt records a
// new refusal or the caller clears them.
LockedUploadRetry[] takeDueLockedUploads() {
	lockedUploadRetryMutex.lock();
	scope(exit) lockedUploadRetryMutex.unlock();
	LockedUploadRetry[] due;
	MonoTime now = MonoTime.currTime;
	foreach (key, ref retry; lockedUploadRetries) {
		if (retry.due <= now) {
			due ~= retry;
			retry.due = MonoTime.max;
		}
	}
	return due;
}

// Time until the next locked-upload retry is due, or Duration.max if none
Duration nextLockedUploadDueIn() {
	lockedUploadRetryMutex.lock();
	scope(exit) lockedUploadRetryMutex.unlock();
	Duration next = Duration.max;
	MonoTime now = MonoTime.currTime;
	foreach (retry; lockedUploadRetries) {
		if (retry.due == MonoTime.max) continue;
		Duration remaining = (retry.due > now) ? (retry.due - now) : Duration.zero;
		if (remaining < next) next = remaining;
	}
	return next;
}

Mutex onDemandStateLock() {
	return onDemandStateMutex;
}

// Convert a DB hydration value to a HydrationState. null means hydrated.
HydrationState hydrationStateFromDatabase(string value) {
	if (value == hydrationOnlineOnly) return HydrationState.onlineOnly;
	if (value == hydrationPinned) return HydrationState.pinned;
	return HydrationState.hydrated;
}

// Is this item, or any ancestor of it, pinned?
bool isPinnedOrHasPinnedAncestor(ItemDatabase itemDB, string driveId, string id) {
	string currentDriveId = driveId;
	string currentId = id;
	// Guard against a broken parent chain
	foreach (depth; 0 .. 4096) {
		Item item;
		if (!itemDB.selectById(currentDriveId, currentId, item)) return false;
		if (item.hydration == hydrationPinned) return true;
		if (item.parentId.empty || (item.type == ItemType.root)) return false;
		currentId = item.parentId;
	}
	return false;
}

// Does this item's subtree contain an online-only file?
bool subtreeHasOnlineOnlyItems(ItemDatabase itemDB, string driveId, string id) {
	foreach (child; itemDB.selectChildren(driveId, id)) {
		if (child.hydration == hydrationOnlineOnly) return true;
		if ((child.type == ItemType.dir) && subtreeHasOnlineOnlyItems(itemDB, child.driveId, child.id)) return true;
	}
	return false;
}

// Do two items record the same file content?
bool sameContent(const ref Item a, const ref Item b) {
	if (a.size != b.size) return false;
	if (!a.quickXorHash.empty || !b.quickXorHash.empty) return a.quickXorHash == b.quickXorHash;
	return a.sha256Hash == b.sha256Hash;
}

// Does the file at 'path' match the content hash recorded for 'item'?
bool localFileMatchesItemHash(string path, const ref Item item) {
	if (!item.quickXorHash.empty) return item.quickXorHash == computeQuickXorHash(path);
	if (!item.sha256Hash.empty) return item.sha256Hash == computeSHA256Hash(path);
	return false;
}

// One in-flight hydration of an item. Concurrent hydrate() callers wait on it.
private final class HydrationInFlight {
	bool done;
	int errnoCode;   // 0 on success
	string message;
}

// Thread-safe hydration service called from FUSE worker threads.
// It never touches SyncEngine state and only uses the dependencies passed to the constructor.
final class HydrationService {
	private ApplicationConfig appConfig;
	private ItemDatabase itemDB;
	private string backingDir;
	private string stagingDir;
	private bool disableDownloadValidation;
	private bool disablePermissionSet;
	private int filePermissions;
	private long spaceReservation;

	private Mutex serviceMutex;
	private Condition serviceCondition;
	private HydrationInFlight[string] inFlight;
	private bool shuttingDown;
	// Hydration threads currently inside a database section; shutdown() waits for them
	private int databaseUsers;
	// Set by shutdown(); aborts in-progress transfers of this service's OneDriveApi instances
	private shared bool abortTransfers;
	// Directory states computed by stateOf(), valid for a short time and until any hydration write
	private struct CachedDirectoryState {
		HydrationState state;
		ulong generation;
		MonoTime computedAt;
	}
	private CachedDirectoryState[string] directoryStateCache;
	private Mutex directoryStateCacheMutex;
	private enum directoryStateCacheTtl = dur!"seconds"(2);
	private enum directoryStateCacheLimit = 10_000;
	private struct CachedTransientState {
		TransientState state;
		ulong generation;
		MonoTime computedAt;
	}
	private CachedTransientState[string] transientDirectoryCache;
	private struct CachedWebUrl {
		string eTag;
		string url;
	}
	private CachedWebUrl[string] webUrlCache;
	// Background worker for requestAction(); started on first use
	private enum actionQueueLimit = 10_000;
	private OnDemandActionRequest[] actionQueue;
	private Thread actionWorker;
	private bool actionWorkerRunning;

	this(ApplicationConfig appConfig, ItemDatabase itemDB, string backingDir) {
		this.appConfig = appConfig;
		this.itemDB = itemDB;
		this.backingDir = buildNormalizedPath(absolutePath(backingDir));
		// Staging lives beside the backing directory so the final rename stays on one filesystem
		// and partial downloads never appear inside the mount
		this.stagingDir = buildNormalizedPath(buildPath(dirName(this.backingDir), "." ~ baseName(this.backingDir) ~ ".staging"));
		// Read configuration once; appConfig is owned by the main thread
		this.disableDownloadValidation = appConfig.getValueBool("disable_download_validation");
		this.disablePermissionSet = appConfig.getValueBool("disable_permission_set");
		this.filePermissions = appConfig.returnRequiredFilePermissions();
		this.spaceReservation = appConfig.getValueLong("space_reservation");
		serviceMutex = new Mutex();
		serviceCondition = new Condition(serviceMutex);
		directoryStateCacheMutex = new Mutex();
	}

	// An open or create of a handle on this item (FUSE layer). A file with open handles is never dehydrated.
	void noteOpen(string driveId, string id) {
		onDemandStateMutex.lock();
		scope(exit) onDemandStateMutex.unlock();
		onDemandOpenHandles[itemKey(driveId, id)]++;
	}

	// The release of a handle counted by noteOpen(). An unmatched call is ignored.
	void noteClose(string driveId, string id) {
		bool lastClose = false;
		{
			onDemandStateMutex.lock();
			scope(exit) onDemandStateMutex.unlock();
			string key = itemKey(driveId, id);
			if (auto count = key in onDemandOpenHandles) {
				if (*count <= 1) {
					onDemandOpenHandles.remove(key);
					lastClose = true;
				} else {
					(*count)--;
				}
			}
		}
		// An online change deferred while the file was open is re-evaluated on the main thread
		if (lastClose) deferredItemClosed(driveId, id);
	}

	// File: its database state. Directory: pinned if it is pinned, otherwise online-only if any
	// file below it is online-only, otherwise hydrated.
	HydrationState stateOf(string driveId, string id) {
		Item item;
		if (!itemDB.selectById(driveId, id, item)) {
			throw new HydrationError(ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		}
		if ((item.type == ItemType.dir) || (item.type == ItemType.root)) {
			if (item.hydration == hydrationPinned) return HydrationState.pinned;
			string key = driveId ~ "/" ~ id;
			ulong generation = itemDB.hydrationGeneration();
			MonoTime now = MonoTime.currTime;
			directoryStateCacheMutex.lock();
			if (auto cached = key in directoryStateCache) {
				if ((cached.generation == generation) && (now - cached.computedAt < directoryStateCacheTtl)) {
					HydrationState state = cached.state;
					directoryStateCacheMutex.unlock();
					return state;
				}
			}
			directoryStateCacheMutex.unlock();

			HydrationState state = subtreeHasOnlineOnlyItems(itemDB, driveId, id) ? HydrationState.onlineOnly : HydrationState.hydrated;
			directoryStateCacheMutex.lock();
			if (directoryStateCache.length >= directoryStateCacheLimit) directoryStateCache = null;
			directoryStateCache[key] = CachedDirectoryState(state, generation, now);
			directoryStateCacheMutex.unlock();
			return state;
		}
		return hydrationStateFromDatabase(item.hydration);
	}

	// Perform an action requested through the mount or the CLI. Never downloads in the calling
	// thread: file download/pin and every directory action are queued to a background worker.
	// File unpin and free run now; free throws HydrationError(EBUSY) when refused.
	void requestAction(string driveId, string id, OnDemandAction action) {
		if (isShuttingDown()) throw new HydrationError(EIO, "Hydration service is shutting down");
		Item item;
		if (!itemDB.selectById(driveId, id, item)) {
			throw new HydrationError(ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		}
		bool isDirectory = (item.type == ItemType.dir) || (item.type == ItemType.root);
		if (!isDirectory && (item.type != ItemType.file)) {
			throw new HydrationError(EIO, "On-demand actions are not supported for shared items");
		}

		if (!isDirectory) {
			final switch (action) {
				case OnDemandAction.unpin:
					unpin(driveId, id);
					return;
				case OnDemandAction.free:
					// As on Windows, freeing a file removes its own pin, and also frees a file that is kept
					// only because its folder is pinned (the folder then holds this one online-only file)
					if (!dehydrateFile(driveId, id, true)) {
						throw new HydrationError(EBUSY, "The file has local changes that are not uploaded");
					}
					return;
				case OnDemandAction.download:
				case OnDemandAction.pin:
					break;
			}
		}

		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		if (shuttingDown) throw new HydrationError(EIO, "Hydration service is shutting down");
		// Coalesce: a newer action for the same item replaces a queued one
		size_t queuedBefore = actionQueue.length;
		actionQueue = actionQueue.filter!(queued => !((queued.driveId == driveId) && (queued.id == id))).array;
		if ((actionQueue.length == queuedBefore) && (actionQueue.length >= actionQueueLimit)) {
			addLogEntry("On-demand: refusing '" ~ to!string(action) ~ "' for " ~ item.name ~ ": " ~ to!string(actionQueueLimit) ~ " actions are already queued");
			throw new HydrationError(EAGAIN, "Too many on-demand actions are queued");
		}
		actionQueue ~= OnDemandActionRequest(driveId, id, action);
		if (actionWorker is null) {
			actionWorkerRunning = true;
			actionWorker = new Thread(&actionWorkerLoop);
			actionWorker.isDaemon = true;
			actionWorker.start();
		}
		serviceCondition.notifyAll();
		addLogEntry("On-demand: queued '" ~ to!string(action) ~ "' for " ~ item.name);
	}

	// Blocks until the file is in the backing dir with a verified hash, the backing mtime set
	// from the DB, and DB state H (or P if pinned). Concurrent calls for the same item wait on
	// the one download.
	void hydrate(string driveId, string id) {
		string key = driveId ~ "/" ~ id;
		HydrationInFlight entry;
		bool owner = false;

		serviceMutex.lock();
		try {
			if (shuttingDown) throw new HydrationError(EIO, "Hydration service is shutting down");
			auto existing = key in inFlight;
			if (existing !is null) {
				entry = *existing;
			} else {
				entry = new HydrationInFlight();
				inFlight[key] = entry;
				owner = true;
			}
		} finally {
			serviceMutex.unlock();
		}

		if (owner) {
			int errnoCode = 0;
			string message;
			try {
				performHydrate(driveId, id);
			} catch (HydrationError e) {
				errnoCode = e.errnoCode;
				message = e.msg;
			} catch (Exception e) {
				errnoCode = EIO;
				message = e.msg;
			}

			serviceMutex.lock();
			entry.done = true;
			entry.errnoCode = errnoCode;
			entry.message = message;
			inFlight.remove(key);
			serviceCondition.notifyAll();
			serviceMutex.unlock();

			if (errnoCode != 0) throw new HydrationError(errnoCode, message);
			return;
		}

		// Wait on the download started by another caller
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		while (!entry.done && !shuttingDown) {
			serviceCondition.wait();
		}
		if (!entry.done) throw new HydrationError(EIO, "Hydration service is shutting down");
		if (entry.errnoCode != 0) throw new HydrationError(entry.errnoCode, entry.message);
	}

	// Free up space. Only if the backing file matches the DB hash and has no pending local
	// change. Deletes the backing file, sets DB state O. Returns false if refused (dirty, pinned).
	bool dehydrate(string driveId, string id) {
		return dehydrateFile(driveId, id, false);
	}

	// dehydrate(); with 'explicitRequest' (free up space on this file) a pin of the file itself or of a
	// folder above it does not refuse: the file becomes online-only (unpinned)
	private bool dehydrateFile(string driveId, string id, bool explicitRequest) {
		lockForStateWrite();
		scope(exit) unlockForStateWrite();

		Item item;
		if (!itemDB.selectById(driveId, id, item)) {
			throw new HydrationError(ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		}
		if (item.type != ItemType.file) return false;
		if (!explicitRequest) {
			if (item.hydration == hydrationPinned) return false;
			if (isPinnedOrHasPinnedAncestor(itemDB, driveId, id)) return false;
		}
		// An open handle may be reading or writing the backing file
		if (itemKey(driveId, id) in onDemandOpenHandles) {
			throw new HydrationError(EBUSY, "The file is open");
		}

		string backingPath = backingPathFor(driveId, id);
		if (item.hydration == hydrationOnlineOnly) {
			// An online-only file with a backing file holds a local change that is not uploaded yet
			return !exists(backingPath);
		}
		if (!exists(backingPath)) {
			// Never leave a hydrated state for an absent file: that would read as a local deletion
			itemDB.setHydration(driveId, id, hydrationOnlineOnly);
			return true;
		}
		if (!isFile(backingPath)) return false;

		// A local modification that has not been uploaded yet makes the file dirty
		if (!localFileMatchesItemHash(backingPath, item)) {
			if (verboseLogging) {addLogEntry("On-demand: refusing to free up space for a file with local changes: " ~ backingPath, ["verbose"]);}
			return false;
		}

		// Record online-only before removing the file, so an absent file is never observed with a hydrated state
		string previousState = item.hydration;
		itemDB.setHydration(driveId, id, hydrationOnlineOnly);
		try {
			std.file.remove(backingPath);
		} catch (FileException e) {
			itemDB.setHydration(driveId, id, previousState);
			addLogEntry("On-demand: unable to free up space for " ~ backingPath ~ ": " ~ e.msg);
			throw new HydrationError(EIO, "Unable to remove the backing file: " ~ e.msg);
		}
		if (verboseLogging) {addLogEntry("On-demand: freed up space for " ~ backingPath, ["verbose"]);}
		return true;
	}

	// Set P and hydrate. For a directory, pin it and hydrate every file below it.
	void pin(string driveId, string id) {
		Item item;
		if (!itemDB.selectById(driveId, id, item)) {
			throw new HydrationError(ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		}

		if ((item.type == ItemType.dir) || (item.type == ItemType.root)) {
			lockForStateWrite();
			itemDB.setHydration(driveId, id, hydrationPinned);
			unlockForStateWrite();
			HydrationError firstError;
			hydrateSubtree(driveId, id, firstError);
			if (firstError !is null) throw firstError;
			return;
		}

		// Hydrate first: a pinned state must never be recorded for an absent file
		hydrate(driveId, id);
		lockForStateWrite();
		scope(exit) unlockForStateWrite();
		if (exists(backingPathFor(driveId, id))) {
			itemDB.setHydration(driveId, id, hydrationPinned);
		} else {
			throw new HydrationError(EIO, "Pinned file is not present after hydration");
		}
	}

	// Set H. For a directory, set H on it and on every pinned item below it (no dehydration).
	// A pinned file that is absent becomes O instead, as an absent H file reads as a local deletion.
	void unpin(string driveId, string id) {
		lockForStateWrite();
		scope(exit) unlockForStateWrite();

		Item item;
		if (!itemDB.selectById(driveId, id, item)) {
			throw new HydrationError(ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		}
		unpinLocked(item);
	}

	// Create an empty backing file for an online-only item (O_TRUNC / truncate to 0), without a
	// download. Waits for a hydration commit of the item in progress. Returns false if the item
	// is not online-only. An existing backing file of an online-only item is truncated.
	bool createEmpty(string driveId, string id) {
		lockForStateWrite();
		scope(exit) unlockForStateWrite();

		Item item;
		if (!itemDB.selectById(driveId, id, item)) {
			throw new HydrationError(ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		}
		if ((item.type != ItemType.file) || (item.hydration != hydrationOnlineOnly)) return false;

		string backingPath = backingPathFor(driveId, id);
		// Never create missing parents: the database path may be stale after a local folder move
		if (!exists(dirName(backingPath))) {
			throw new HydrationError(EAGAIN, "The backing parent directory does not exist: " ~ dirName(backingPath));
		}
		try {
			std.file.write(backingPath, "");
			if (!disablePermissionSet) {
				backingPath.setAttributes(filePermissions);
			}
		} catch (FileException e) {
			throw new HydrationError(EIO, "Unable to create an empty backing file: " ~ e.msg);
		}
		return true;
	}

	// Cancel waiting callers with EIO, refuse new hydrations, abort in-progress transfers and
	// wait (bounded) for them to finish, then wait for any database section to complete
	void shutdown() {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		shuttingDown = true;
		atomicStore(abortTransfers, true);
		serviceCondition.notifyAll();

		// In-progress downloads stop at their next progress callback or retry decision
		MonoTime deadline = MonoTime.currTime + dur!"seconds"(30);
		while (((inFlight.length > 0) || actionWorkerRunning) && (MonoTime.currTime < deadline)) {
			serviceCondition.wait(dur!"msecs"(200));
		}
		if (actionWorkerRunning) {
			addLogEntry("WARNING: On-demand: the action worker did not stop within 30 seconds");
		} else if (actionWorker !is null) {
			// The worker has left its loop; reap the thread
			serviceMutex.unlock();
			actionWorker.join(false);
			serviceMutex.lock();
			actionWorker = null;
		}
		if (inFlight.length > 0) {
			addLogEntry("WARNING: On-demand: " ~ to!string(inFlight.length) ~ " hydration(s) did not stop within 30 seconds; they will not update the database");
		}
		// A hydration past its download may be committing; no new database section can start now
		deadline = MonoTime.currTime + dur!"seconds"(30);
		while ((databaseUsers > 0) && (MonoTime.currTime < deadline)) {
			serviceCondition.wait(dur!"msecs"(200));
		}
		if (databaseUsers > 0) {
			addLogEntry("WARNING: On-demand: a hydration database update did not complete within 30 seconds");
		}
	}

	private void unpinLocked(Item item) {
		if ((item.type == ItemType.dir) || (item.type == ItemType.root)) {
			if (item.hydration == hydrationPinned) itemDB.setHydration(item.driveId, item.id, hydrationHydrated);
			foreach (child; itemDB.selectChildren(item.driveId, item.id)) {
				unpinLocked(child);
			}
			return;
		}
		if (item.hydration != hydrationPinned) return;
		// An absent pinned file must become online-only, never hydrated (which would read as a local deletion)
		string newState = exists(backingPathFor(item.driveId, item.id)) ? hydrationHydrated : hydrationOnlineOnly;
		itemDB.setHydration(item.driveId, item.id, newState);
	}

	private void hydrateSubtree(string driveId, string id, ref HydrationError firstError) {
		foreach (child; itemDB.selectChildren(driveId, id)) {
			if (isShuttingDown()) return;
			if (child.type == ItemType.dir) {
				hydrateSubtree(child.driveId, child.id, firstError);
			} else if (child.type == ItemType.file) {
				try {
					hydrate(child.driveId, child.id);
					// hydrate() records P for a file under a pinned ancestor
				} catch (HydrationError e) {
					if (e.errnoCode == EAGAIN) {
						addLogEntry("On-demand: skipping pinned file " ~ child.name ~ " for now: " ~ e.msg);
						continue;
					}
					addLogEntry("On-demand: unable to hydrate pinned file " ~ child.name ~ ": " ~ e.msg);
					if (firstError is null) firstError = e;
				}
			}
		}
	}

	private bool isShuttingDown() {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		return shuttingDown;
	}

	// Background worker: runs queued actions one at a time until shutdown
	private void actionWorkerLoop() {
		scope(exit) {
			serviceMutex.lock();
			actionWorkerRunning = false;
			serviceCondition.notifyAll();
			serviceMutex.unlock();
		}
		while (true) {
			OnDemandActionRequest request;
			serviceMutex.lock();
			while ((actionQueue.length == 0) && !shuttingDown) {
				serviceCondition.wait();
			}
			if (shuttingDown) {
				foreach (dropped; actionQueue) {
					addLogEntry("On-demand: shutting down, dropping queued '" ~ to!string(dropped.action) ~ "' for item " ~ dropped.id);
				}
				actionQueue = null;
				serviceMutex.unlock();
				return;
			}
			request = actionQueue[0];
			actionQueue = actionQueue[1 .. $];
			serviceMutex.unlock();

			if (!enterDatabase()) return;
			try {
				performAction(request);
			} catch (Exception e) {
				addLogEntry("On-demand: action '" ~ to!string(request.action) ~ "' failed: " ~ e.msg);
			}
			leaveDatabase();
		}
	}

	private void performAction(OnDemandActionRequest request) {
		Item item;
		if (!itemDB.selectById(request.driveId, request.id, item)) {
			addLogEntry("On-demand: action '" ~ to!string(request.action) ~ "' skipped, the item is no longer in the database");
			return;
		}
		string itemPath = itemDB.computePath(request.driveId, request.id);
		bool isDirectory = (item.type == ItemType.dir) || (item.type == ItemType.root);
		addLogEntry("On-demand: " ~ to!string(request.action) ~ " " ~ itemPath ~ " ...");

		final switch (request.action) {
			case OnDemandAction.download:
				if (isDirectory) {
					HydrationError firstError;
					hydrateSubtree(request.driveId, request.id, firstError);
				} else {
					hydrate(request.driveId, request.id);
				}
				break;
			case OnDemandAction.pin:
				try {
					pin(request.driveId, request.id);
				} catch (HydrationError e) {
					// For a directory the per-file failures were logged by hydrateSubtree
					if (!isDirectory) throw e;
				}
				break;
			case OnDemandAction.unpin:
				unpin(request.driveId, request.id);
				break;
			case OnDemandAction.free:
				if (isDirectory) {
					unpin(request.driveId, request.id);
					dehydrateSubtree(request.driveId, request.id);
				} else if (!dehydrate(request.driveId, request.id)) {
					addLogEntry("On-demand: free up space refused (pinned or local changes): " ~ itemPath);
				}
				break;
		}
		addLogEntry("On-demand: " ~ to!string(request.action) ~ " " ~ itemPath ~ " ... done");
	}

	// Free up space for every file below a directory; refused files stay local and are logged
	private void dehydrateSubtree(string driveId, string id) {
		foreach (child; itemDB.selectChildren(driveId, id)) {
			if (isShuttingDown()) return;
			if (child.type == ItemType.dir) {
				dehydrateSubtree(child.driveId, child.id);
			} else if (child.type == ItemType.file) {
				try {
					if (!dehydrate(child.driveId, child.id)) {
						addLogEntry("On-demand: free up space refused, the file stays local (pinned or local changes): " ~ itemDB.computePath(child.driveId, child.id));
					}
				} catch (HydrationError e) {
					addLogEntry("On-demand: unable to free up space for " ~ child.name ~ ": " ~ e.msg);
				}
			}
		}
	}

	private void removeStagingFile(string stagingPath) {
		try {
			if (exists(stagingPath)) std.file.remove(stagingPath);
		} catch (FileException e) {
			addLogEntry("On-demand: unable to remove staging file " ~ stagingPath ~ ": " ~ e.msg);
		}
	}

	private string backingPathFor(string driveId, string id) {
		string relativePath = itemDB.computePath(driveId, id);
		return buildNormalizedPath(buildPath(backingDir, relativePath));
	}

	// Every hydration-state write holds the database transaction lock first, so it never joins an
	// open engine transaction, then the on-demand state lock
	private void lockForStateWrite() {
		itemDB.transactionLock().lock();
		onDemandStateMutex.lock();
	}

	private void unlockForStateWrite() {
		onDemandStateMutex.unlock();
		itemDB.transactionLock().unlock();
	}

	// Enter a database section of a hydration. Returns false once shutdown() has been called.
	private bool enterDatabase() {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		if (shuttingDown) return false;
		databaseUsers++;
		return true;
	}

	private void leaveDatabase() {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		databaseUsers--;
		serviceCondition.notifyAll();
	}

	private void performHydrate(string driveId, string id) {
		setTransientState(driveId, id, TransientState.syncing);
		try {
			// A concurrent online change can alter the item while it downloads; retry a bounded number of times
			foreach (attempt; 0 .. 3) {
				if (performHydrateAttempt(driveId, id)) {
					setTransientState(driveId, id, TransientState.none);
					return;
				}
				if (debugLogging) {addLogEntry("On-demand: database item changed during hydration, retrying: " ~ driveId ~ " " ~ id, ["debug"]);}
			}
			throw new HydrationError(EIO, "Item changed repeatedly during hydration");
		} catch (HydrationError e) {
			// Offline, not ready yet or shutting down are not errors of the item
			bool transientFailure = (e.errnoCode == ENETUNREACH) || (e.errnoCode == EAGAIN) || isShuttingDown();
			setTransientState(driveId, id, transientFailure ? TransientState.none : TransientState.error);
			throw e;
		} catch (Exception e) {
			setTransientState(driveId, id, TransientState.error);
			throw e;
		}
	}

	// Transient state of a file, or for a directory the most significant transient state of any
	// file below it (syncing, then pending, then error). Never throws, never uses the network.
	TransientState transientStateOf(string driveId, string id) {
		try {
			Item item;
			if (!itemDB.selectById(driveId, id, item)) return TransientState.none;
			if ((item.type != ItemType.dir) && (item.type != ItemType.root)) return transientStateOfItem(driveId, id);

			string key = "transient:" ~ itemKey(driveId, id);
			ulong generation = itemDB.hydrationGeneration() + atomicLoad(transientStateWrites);
			MonoTime now = MonoTime.currTime;
			directoryStateCacheMutex.lock();
			if (auto cached = key in transientDirectoryCache) {
				if ((cached.generation == generation) && (now - cached.computedAt < directoryStateCacheTtl)) {
					TransientState state = cached.state;
					directoryStateCacheMutex.unlock();
					return state;
				}
			}
			directoryStateCacheMutex.unlock();

			TransientState result = TransientState.none;
			foreach (entryKey, state; transientStatesSnapshot()) {
				if (transientRank(state) <= transientRank(result)) continue;
				auto separator = indexOf(entryKey, '/');
				if (separator < 0) continue;
				// Keys hold the drive id in lower case; an item below this directory is on its drive
				if (entryKey[0 .. separator] != std.uni.toLower(driveId)) continue;
				if (isBelow(driveId, entryKey[separator + 1 .. $], driveId, id)) result = state;
			}

			directoryStateCacheMutex.lock();
			if (transientDirectoryCache.length >= directoryStateCacheLimit) transientDirectoryCache = null;
			transientDirectoryCache[key] = CachedTransientState(result, generation, now);
			directoryStateCacheMutex.unlock();
			return result;
		} catch (Exception e) {
			return TransientState.none;
		}
	}

	private static int transientRank(TransientState state) {
		final switch (state) {
			case TransientState.none: return 0;
			case TransientState.error: return 1;
			case TransientState.pending: return 2;
			case TransientState.syncing: return 3;
		}
	}

	// Is the item driveId/id below the directory directoryDriveId/directoryId?
	private bool isBelow(string driveId, string id, string directoryDriveId, string directoryId) {
		string currentId = id;
		foreach (depth; 0 .. 4096) {
			Item item;
			if (!itemDB.selectById(driveId, currentId, item)) return false;
			if (item.parentId.empty) return false;
			if ((driveId == directoryDriveId) && (item.parentId == directoryId)) return true;
			currentId = item.parentId;
		}
		return false;
	}

	// The item's OneDrive web URL (Graph webUrl). Never hydrates. Cached per item and eTag.
	// Throws HydrationError(ENODATA) for an item not in the database, (EIO) when offline or on failure.
	string webUrlOf(string driveId, string id) {
		if (isShuttingDown()) throw new HydrationError(EIO, "Hydration service is shutting down");
		Item item;
		if (!itemDB.selectById(driveId, id, item)) {
			throw new HydrationError(ENODATA, "Item is not in the local database");
		}
		string key = itemKey(driveId, id);
		directoryStateCacheMutex.lock();
		if (auto cached = key in webUrlCache) {
			if (cached.eTag == item.eTag) {
				string url = cached.url;
				directoryStateCacheMutex.unlock();
				return url;
			}
		}
		directoryStateCacheMutex.unlock();

		auto probe = probeMicrosoftService(appConfig, false);
		if (!probe.reachable) throw new HydrationError(EIO, "Microsoft OneDrive is not reachable");

		// Bound the request to about 10 seconds: a watchdog aborts the transfer through the API abort flag
		shared bool requestAbort = false;
		shared bool requestDone = false;
		auto watchdog = new Thread({
			MonoTime deadline = MonoTime.currTime + dur!"seconds"(10);
			while (!atomicLoad(requestDone) && (MonoTime.currTime < deadline) && !atomicLoad(abortTransfers)) {
				Thread.sleep(dur!"msecs"(100));
			}
			if (!atomicLoad(requestDone)) atomicStore(requestAbort, true);
		});
		watchdog.isDaemon = true;
		watchdog.start();

		OneDriveApi api = new OneDriveApi(appConfig);
		scope(exit) {
			atomicStore(requestDone, true);
			api.releaseCurlEngine();
			api = null;
			watchdog.join(false);
		}
		JSONValue onlineItem;
		try {
			api.initialise();
			api.setTransferAbortFlag(&requestAbort);
			onlineItem = api.getPathDetailsById(driveId, id);
		} catch (Exception e) {
			throw new HydrationError(EIO, "Unable to query the online item: " ~ e.msg);
		}
		if (atomicLoad(requestAbort)) throw new HydrationError(EIO, "Timed out querying the online item");
		if ((onlineItem.type != JSONType.object) || !("webUrl" in onlineItem) || (onlineItem["webUrl"].type != JSONType.string) || onlineItem["webUrl"].str.empty) {
			throw new HydrationError(EIO, "Microsoft OneDrive returned no web URL for the item");
		}
		string url = onlineItem["webUrl"].str;
		directoryStateCacheMutex.lock();
		if (webUrlCache.length >= directoryStateCacheLimit) webUrlCache = null;
		webUrlCache[key] = CachedWebUrl(item.eTag, url);
		directoryStateCacheMutex.unlock();
		return url;
	}

	// Returns false when the database item changed during the download and the attempt should be repeated
	private bool performHydrateAttempt(string driveId, string id) {
		Item dbItem;
		string backingPath;
		if (!enterDatabase()) throw new HydrationError(EIO, "Hydration service is shutting down");
		{
			scope(exit) leaveDatabase();
			if (!itemDB.selectById(driveId, id, dbItem)) {
				throw new HydrationError(ENOENT, "Item is not in the local database");
			}
			if ((dbItem.type == ItemType.dir) || (dbItem.type == ItemType.root)) return true;
			if (dbItem.type != ItemType.file) {
				// Shared (remote) items are out of scope for on-demand
				throw new HydrationError(EIO, "Only files on the account drive can be hydrated");
			}
			backingPath = backingPathFor(driveId, id);
		}
		if (!exists(dirName(backingPath))) {
			throw new HydrationError(EAGAIN, "The backing parent directory does not exist: " ~ dirName(backingPath));
		}
		if (exists(backingPath)) {
			// Already present. This includes an online-only file that was truncated and written
			// locally; its content must not be replaced by a download.
			return true;
		}

		// A request while offline must not block in the API retry loop
		auto probe = probeMicrosoftService(appConfig, false);
		if (!probe.reachable) {
			throw new HydrationError(ENETUNREACH, "Microsoft OneDrive is not reachable");
		}

		// Fetch the current online item. Do not depend on possibly stale DB content fields.
		OneDriveApi api = new OneDriveApi(appConfig);
		scope(exit) {
			api.releaseCurlEngine();
			api = null;
		}
		api.initialise();
		api.setTransferAbortFlag(&abortTransfers);

		JSONValue onlineItem;
		try {
			onlineItem = api.getPathDetailsById(driveId, id);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) throw new HydrationError(ENOENT, "Item no longer exists online");
			throw new HydrationError(EIO, "Unable to query the online item: " ~ e.msg);
		}
		if (atomicLoad(abortTransfers)) throw new HydrationError(EIO, "Hydration service is shutting down");
		if ((onlineItem.type != JSONType.object) || isItemDeleted(onlineItem)) {
			throw new HydrationError(ENOENT, "Item no longer exists online");
		}
		if (!isItemFile(onlineItem)) {
			throw new HydrationError(EIO, "Online item is not a file");
		}
		if (isMalware(onlineItem)) {
			addLogEntry("ERROR: MALWARE DETECTED IN FILE - HYDRATION REFUSED: " ~ backingPath, ["info", "notify"]);
			throw new HydrationError(EIO, "Online item is flagged as malware");
		}

		Item onlineDbItem = makeDatabaseItem(onlineItem);
		long fileSize = hasFileSize(onlineItem) ? onlineItem["size"].integer : 0;
		string expectedQuickXorHash = onlineDbItem.quickXorHash;
		string expectedSHA256Hash = onlineDbItem.sha256Hash;

		JSONValue onlineHash;
		if (!expectedQuickXorHash.empty) {
			onlineHash = JSONValue(["quickXorHash": JSONValue(expectedQuickXorHash)]);
		} else if (!expectedSHA256Hash.empty) {
			onlineHash = JSONValue(["sha256Hash": JSONValue(expectedSHA256Hash)]);
		} else {
			onlineHash = JSONValue(["hashMissing": JSONValue("none")]);
		}

		// Staging area beside the backing directory
		if (!exists(stagingDir)) mkdirRecurse(stagingDir);
		ulong freeSpace = getAvailableDiskSpace(stagingDir);
		if ((to!long(freeSpace) < spaceReservation) || (fileSize > to!long(freeSpace) - spaceReservation)) {
			throw new HydrationError(ENOSPC, "Insufficient local disk space to hydrate the file");
		}
		string stagingPath = buildPath(stagingDir, driveId ~ "_" ~ id);
		scope(exit) removeStagingFile(stagingPath);

		// Verify size and hash before the download layer promotes the staging file
		string verificationFailure;
		bool delegate(DownloadCommitInfo) verifyDownload = (DownloadCommitInfo info) {
			if (disableDownloadValidation) {
				if (verboseLogging) {addLogEntry("WARNING: Skipping hydration integrity check for: " ~ backingPath, ["verbose"]);}
				return true;
			}
			string downloadedHash;
			string expectedHash;
			if (!expectedQuickXorHash.empty) {
				expectedHash = expectedQuickXorHash;
				downloadedHash = info.hasStreamedQuickXorHash ? info.streamedQuickXorHash : info.generatedQuickXorHash;
			} else if (!expectedSHA256Hash.empty) {
				expectedHash = expectedSHA256Hash;
				downloadedHash = info.generatedSHA256Hash;
			} else {
				verificationFailure = "the online item has no content hash";
				return false;
			}
			if (info.size != fileSize) {
				verificationFailure = "size mismatch: expected " ~ to!string(fileSize) ~ ", actual " ~ to!string(info.size);
				return false;
			}
			if (downloadedHash != expectedHash) {
				verificationFailure = "hash mismatch: expected " ~ expectedHash ~ ", actual " ~ downloadedHash;
				return false;
			}
			return true;
		};

		addLogEntry("On-demand: hydrating " ~ backingPath);
		CurlResponse response;
		try {
			response = api.downloadById(driveId, id, stagingPath, fileSize, onlineHash, 0, verifyDownload);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) throw new HydrationError(ENOENT, "Item no longer exists online");
			throw new HydrationError(EIO, "Download failed: " ~ e.msg);
		} catch (FileException e) {
			throw new HydrationError(EIO, "Local file system error during download: " ~ e.msg);
		}
		if ((response is null) || !exists(stagingPath)) {
			if (!verificationFailure.empty) {
				addLogEntry("ERROR: On-demand hydration integrity check failed for " ~ backingPath ~ ": " ~ verificationFailure);
			}
			throw new HydrationError(EIO, verificationFailure.empty ? "Download failed" : "Download integrity check failed: " ~ verificationFailure);
		}

		if (!disablePermissionSet) {
			stagingPath.setAttributes(filePermissions);
		}

		// Commit: move into the backing dir and record the state atomically with respect to the engine.
		// Only the hydration column is written, so concurrent engine updates of the row are kept.
		if (!enterDatabase()) throw new HydrationError(EIO, "Hydration service is shutting down");
		scope(exit) leaveDatabase();
		lockForStateWrite();
		scope(exit) unlockForStateWrite();

		Item currentItem;
		if (!itemDB.selectById(driveId, id, currentItem)) {
			throw new HydrationError(ENOENT, "Item was removed from the local database during hydration");
		}
		// The downloaded bytes must be the content the database records; otherwise the file would
		// look locally modified and be uploaded over the version the database describes
		if (!sameContent(currentItem, onlineDbItem)) {
			if (!sameContent(currentItem, dbItem)) {
				// The engine applied a different online version while downloading: start again
				return false;
			}
			throw new HydrationError(EIO, "The online file is newer than the local database; it can be opened after the next sync");
		}
		// The path moved while downloading
		string currentBackingPath = backingPathFor(driveId, id);
		if (currentBackingPath != backingPath) {
			return false;
		}
		if (exists(backingPath)) {
			// Something created the file locally meanwhile; never overwrite local content
			return true;
		}

		// Never create missing parents: the database path may be stale after a local folder move
		// that has not been applied yet
		if (!exists(dirName(backingPath))) {
			throw new HydrationError(EAGAIN, "The backing parent directory does not exist: " ~ dirName(backingPath));
		}

		// The backing mtime comes from the database record
		setTimes(stagingPath, currentItem.mtime, currentItem.mtime);
		try {
			rename(stagingPath, backingPath);
		} catch (FileException e) {
			throw new HydrationError(EIO, "Unable to move hydrated file into the backing directory: " ~ e.msg);
		}

		bool pinned = (currentItem.hydration == hydrationPinned) || isPinnedOrHasPinnedAncestor(itemDB, driveId, id);
		itemDB.setHydration(driveId, id, pinned ? hydrationPinned : hydrationHydrated);

		addLogEntry("On-demand: hydrating " ~ backingPath ~ " ... done");
		return true;
	}
}
