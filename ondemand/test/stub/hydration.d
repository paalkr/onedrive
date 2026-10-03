/*
 * Test stub of the engine's src/hydration.d (see ondemand/CONTRACT.md).
 * Same public API as the classes and types the FUSE layer uses;
 * "downloads" copy from a local fake remote directory. Not part of the
 * onedrive build.
 *
 * Like the real module the state lives in the item table's hydration
 * column and the backing path comes from ItemDatabase.computePath(), so a
 * download lands where the database (not the mount) says the item is.
 * setStateForTest() seeds the state and the fake remote file of an item.
 */
module hydration;

import core.sync.condition;
import core.sync.mutex;
import core.thread : Thread;
import core.time : dur;
import errno = core.stdc.errno;
import std.file;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.conv : text;

/* One write(2) per line: the log is shared with the client's stdout, and
   std.stdio's unbuffered stderr writes each argument separately */
private void stubLog(T...)(T args)
{
	import core.sys.posix.unistd : write;
	string line = text(args) ~ "\n";
	write(2, line.ptr, line.length);
}

import config;
import itemdb;
import ondemand : notifyBackingChange;

enum HydrationState { onlineOnly, hydrated, pinned }

/* As the real module: staging inside the physical sync_dir, hidden by the FUSE layer */
enum string onDemandStagingDirName = ".onedrive-ondemand:staging";

bool isOnDemandStagingPath(const(char)[] path)
{
	import std.algorithm.searching : startsWith;
	const(char)[] p = path;
	while (p.length && (p[0] == '/' || (p.length >= 2 && p[0] == '.' && p[1] == '/')))
		p = (p[0] == '/') ? p[1 .. $] : p[2 .. $];
	return (p == onDemandStagingDirName) || startsWith(p, onDemandStagingDirName ~ "/");
}

enum OnDemandAction { download, pin, unpin, free }

enum TransientState { none, syncing, pending, error }

class HydrationError : Exception
{
	int errnoCode;
	this(int errnoCode, string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
		this.errnoCode = errnoCode;
	}
}

struct OnDemandWake {}

enum OnDemandChangeKind { changed, createDir, deleted, moved }

struct OnDemandLocalChange
{
	OnDemandChangeKind kind;
	string path;
	string oldPath;
}

/* Every path ever pushed, so noteClose can check the order of events */
private __gshared bool[string] pushedPaths;
private __gshared Object historyLock;
shared static this() { historyLock = new Object(); }

final class OnDemandChangeQueue
{
	private Mutex lock;
	private OnDemandLocalChange[] items;

	this()
	{
		lock = new Mutex();
	}

	void push(OnDemandLocalChange change)
	{
		lock.lock();
		scope(exit) lock.unlock();
		items ~= change;
		synchronized (historyLock) pushedPaths[change.path] = true;
	}

	OnDemandLocalChange[] drain()
	{
		lock.lock();
		scope(exit) lock.unlock();
		auto result = items;
		items = null;
		return result;
	}
}

final class HydrationService
{
	/* Test knobs, set before mounting */
	__gshared string fakeRemoteDir;
	__gshared uint downloadDelayMsecs;

	private ItemDatabase itemDB;
	private string backingDir;
	private Mutex lock;
	private Condition done;
	private string[string] remotePaths;    // key -> "a/b" in fakeRemoteDir
	private bool[string] inFlight;
	private bool stopping;
	private uint[string] downloads;
	private uint[string] openCount;
	private uint[string] scannerCount;   // of openCount, the handles of on-access scanners
	private TransientState[string] transient;
	private bool[string] deferred;
	__gshared uint webUrlDelayMsecs;

	this(ApplicationConfig appConfig, ItemDatabase itemDB, string backingDir)
	{
		this.itemDB = itemDB;
		this.backingDir = backingDir;
		lock = new Mutex();
		done = new Condition(lock);
	}

	private static string key(string driveId, string id)
	{
		return driveId ~ "/" ~ id;
	}

	private static string dbValue(HydrationState state)
	{
		final switch (state)
		{
			case HydrationState.onlineOnly: return "O";
			case HydrationState.hydrated: return "H";
			case HydrationState.pinned: return "P";
		}
	}

	/* Ranged reads (as the real service): 128 KiB blocks fetched from the fake remote file and
	   cached per item and content version, so concurrent readers share them; each fetch is logged
	   as "STUB range". The online version is "q:" + contentHash of the fake remote file: a request
	   for another version or size fails with EIO, as the real service does when the database is
	   behind. rangeOffline makes every fetch fail (EIO), as the real service does offline. */
	__gshared bool rangeOffline;
	__gshared uint rangeDelayMsecs = 200;
	private enum size_t rangeBlock = 128 * 1024;
	private ubyte[][size_t][string] rangeBlocks;
	private string[string] rangeBlockVersion;
	private Mutex rangeLock;

	static string contentVersionOf(const ref Item item)
	{
		if (item.quickXorHash.length) return "q:" ~ item.quickXorHash;
		if (item.sha256Hash.length) return "s:" ~ item.sha256Hash;
		if (item.cTag.length) return "c:" ~ item.cTag;
		return "e:" ~ item.eTag;
	}

	bool isHydrating(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		return (key(driveId, id) in inFlight) !is null;
	}

	ubyte[] readRange(string driveId, string id, string contentVersion, long expectedSize, ulong offset, size_t length, ulong reader)
	{
		if (rangeLock is null) synchronized (this) if (rangeLock is null) rangeLock = new Mutex();
		auto k = key(driveId, id);
		string source;
		{
			lock.lock();
			scope(exit) lock.unlock();
			auto remote = k in remotePaths;
			if (remote is null)
				throw new HydrationError(errno.EIO, "no fake remote file for " ~ id);
			source = buildPath(fakeRemoteDir, *remote);
		}
		rangeLock.lock();
		scope(exit) rangeLock.unlock();
		if (rangeOffline)
		{
			stubLog("STUB range offline ", itemDB.computePath(driveId, id));
			throw new HydrationError(errno.EIO, "offline");
		}
		if (!exists(source))
			throw new HydrationError(errno.ENOENT, "gone online");
		if (rangeBlockVersion.get(k, null) != contentVersion)
		{
			rangeBlocks.remove(k);
			rangeBlockVersion[k] = contentVersion;
		}
		if (length == 0 || expectedSize <= 0 || offset >= cast(ulong) expectedSize) return [];
		ulong end = offset + length > cast(ulong) expectedSize ? expectedSize : offset + length;
		size_t first = cast(size_t) (offset / rangeBlock), last = cast(size_t) ((end - 1) / rangeBlock);
		auto blocks = k in rangeBlocks;
		size_t missingFrom = size_t.max, missingTo;
		foreach (b; first .. last + 1)
			if (blocks is null || (b !in *blocks)) { if (missingFrom == size_t.max) missingFrom = b; missingTo = b; }
		if (missingFrom != size_t.max)
		{
			// One read of the fake remote file: the version check and the served bytes are the same content
			if (rangeDelayMsecs) Thread.sleep(dur!"msecs"(rangeDelayMsecs));
			auto content = cast(ubyte[]) std.file.read(source);
			import std.digest.sha : sha1Of;
			import std.digest : toHexString;
			if ("q:" ~ toHexString(sha1Of(content)).idup != contentVersion || cast(long) content.length != expectedSize)
			{
				stubLog("STUB range version mismatch ", itemDB.computePath(driveId, id));
				throw new HydrationError(errno.EIO, "the online file is another version");
			}
			stubLog("STUB range ", itemDB.computePath(driveId, id), " ", missingFrom * rangeBlock, " ", (missingTo - missingFrom + 1) * rangeBlock);
			if (k !in rangeBlocks) rangeBlocks[k] = null;
			foreach (b; missingFrom .. missingTo + 1)
			{
				size_t from = b * rangeBlock;
				size_t to = from + rangeBlock > content.length ? content.length : from + rangeBlock;
				if (from <= to) rangeBlocks[k][b] = content[from .. to].dup;
			}
		}
		ubyte[] result;
		foreach (b; first .. last + 1)
		{
			auto data = rangeBlocks[k][b];
			ulong blockStart = cast(ulong) b * rangeBlock;
			size_t from = cast(size_t) (offset > blockStart ? offset - blockStart : 0);
			size_t to = cast(size_t) (end - blockStart < data.length ? end - blockStart : data.length);
			if (from < to) result ~= data[from .. to];
		}
		return result;
	}

	void setStateForTest(string driveId, string id, string remotePath, HydrationState state)
	{
		lock.lock();
		scope(exit) lock.unlock();
		itemDB.setHydration(driveId, id, dbValue(state));
		remotePaths[key(driveId, id)] = remotePath;
		// A local file seeded as hydrated or pinned holds the online content
		if (state != HydrationState.onlineOnly && exists(targetOf(driveId, id))) storeHash(driveId, id);
	}

	/* The hash rule of the real service: a file is freed only when its local content matches the
	   hash stored in the database (by the download, or by the upload of a local change). The stub's
	   hash is a SHA-1 of the content, kept in the item's quickXorHash column. */
	static string contentHash(string path)
	{
		import std.digest.sha : sha1Of;
		import std.digest : toHexString;
		return toHexString(sha1Of(cast(ubyte[]) std.file.read(path))).idup;
	}

	private void storeHash(string driveId, string id)
	{
		Item item;
		if (!itemDB.selectById(driveId, id, item)) return;
		item.quickXorHash = contentHash(targetOf(driveId, id));
		itemDB.update(item);
	}

	private bool matchesStoredHash(string driveId, string id)
	{
		Item item;
		string target = targetOf(driveId, id);
		return itemDB.selectById(driveId, id, item) && exists(target) && contentHash(target) == item.quickXorHash;
	}

	uint downloadCount(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		return downloads.get(key(driveId, id), 0);
	}

	private HydrationState stateLocked(string driveId, string id)
	{
		Item item;
		if (!itemDB.selectById(driveId, id, item))
			throw new HydrationError(errno.ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		if (item.type == ItemType.dir || item.type == ItemType.root) {
			if (item.hydration == "P") return HydrationState.pinned;
			return subtreeHasOnlineOnly(driveId, id) ? HydrationState.onlineOnly : HydrationState.hydrated;
		}
		if (item.hydration == "O") return HydrationState.onlineOnly;
		if (item.hydration == "P") return HydrationState.pinned;
		return HydrationState.hydrated;
	}

	private bool subtreeHasOnlineOnly(string driveId, string id)
	{
		foreach (child; itemDB.selectChildren(driveId, id)) {
			if (child.hydration == "O") return true;
			if (child.type == ItemType.dir && subtreeHasOnlineOnly(child.driveId, child.id)) return true;
		}
		return false;
	}

	private bool pinnedOrPinnedAncestor(string driveId, string id)
	{
		Item item;
		while (itemDB.selectById(driveId, id, item)) {
			if (item.hydration == "P") return true;
			if (item.parentId.length == 0 || item.type == ItemType.root) return false;
			id = item.parentId;
		}
		return false;
	}

	private string targetOf(string driveId, string id)
	{
		return buildNormalizedPath(buildPath(backingDir, itemDB.computePath(driveId, id)));
	}

	HydrationState stateOf(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		return stateLocked(driveId, id);
	}

	/* Creates the empty backing file of an online-only item instead of
	   downloading it (O_TRUNC). As in the engine (9af10d7) the state stays
	   O until the change is uploaded, an existing backing file is
	   truncated, and it is false for anything but an online-only file. */
	bool createEmpty(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		// The engine waits for a hydration commit in progress; afterwards the state is H
		if (key(driveId, id) in inFlight)
			return false;
		Item item;
		if (!itemDB.selectById(driveId, id, item))
			throw new HydrationError(errno.ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		if (item.type != ItemType.file || stateLocked(driveId, id) != HydrationState.onlineOnly)
			return false;
		string target = targetOf(driveId, id);
		try
		{
			mkdirRecurse(dirName(target));
			std.file.write(target, "");
		}
		catch (FileException e)
			throw new HydrationError(errno.EIO, e.msg);
		// As the real service: the local content exists now, the item is H (and differs from the stored hash until uploaded)
		itemDB.setHydration(driveId, id, "H");
		stubLog("STUB createEmpty ", itemDB.computePath(driveId, id));
		return true;
	}

	void noteLocalContent(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		if (stateLocked(driveId, id) != HydrationState.onlineOnly || !exists(targetOf(driveId, id)))
			return;
		itemDB.setHydration(driveId, id, "H");
		stubLog("STUB noteLocalContent ", itemDB.computePath(driveId, id));
	}

	void hydrate(string driveId, string id, string requestedBy = null)
	{
		auto k = key(driveId, id);
		lock.lock();
		scope(exit) lock.unlock();
		while (k in inFlight && !stopping)
			done.wait();
		if (stopping)
			throw new HydrationError(errno.EIO, "hydration service stopped");
		if (stateLocked(driveId, id) != HydrationState.onlineOnly)
			return;
		auto remote = k in remotePaths;
		if (remote is null)
			throw new HydrationError(errno.ENOENT, "unknown item " ~ k);

		inFlight[k] = true;
		scope(exit)
		{
			inFlight.remove(k);
			done.notifyAll();
		}
		string rel = itemDB.computePath(driveId, id);
		string target = targetOf(driveId, id);
		string source = buildPath(fakeRemoteDir, *remote);
		lock.unlock();
		bool relocked = false;
		scope(exit) if (!relocked) lock.lock();

		stubLog("STUB download ", *remote, " to ", rel);
		if (requestedBy.length) stubLog("STUB hydrating ", rel, " requested by ", requestedBy);
		if (downloadDelayMsecs)
			Thread.sleep(dur!"msecs"(downloadDelayMsecs));
		if (!exists(source))
			throw new HydrationError(errno.ENOENT, "gone online: " ~ *remote);
		/* Download into the hidden staging dir of the physical sync_dir, then rename */
		mkdirRecurse(buildPath(backingDir, onDemandStagingDirName));
		string tmp = buildPath(backingDir, onDemandStagingDirName, "hydrate-tmp-" ~ id);
		copy(source, tmp);
		Item item;
		if (itemDB.selectById(driveId, id, item))
			setTimes(tmp, item.mtime, item.mtime);
		mkdirRecurse(dirName(target));
		rename(tmp, target);

		lock.lock();
		relocked = true;
		downloads[k] = downloads.get(k, 0) + 1;
		itemDB.setHydration(driveId, id, "H");
		storeHash(driveId, id);
		// As the engine (cbd1508): every download commit is reported to the mount
		notifyBackingChange("./" ~ rel, OnDemandChangeKind.changed);
	}

	bool dehydrate(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		if (openCount.get(key(driveId, id), 0) > 0)
			throw new HydrationError(errno.EBUSY, "refused to free open " ~ id);
		if (stateLocked(driveId, id) != HydrationState.hydrated)
			return false;
		// As the real service: a file with local changes that are not uploaded is never freed
		if (exists(targetOf(driveId, id)) && !matchesStoredHash(driveId, id))
			return false;
		string target = targetOf(driveId, id);
		try
		{
			if (exists(target))
				remove(target);
		}
		catch (FileException e)
			throw new HydrationError(errno.EIO, e.msg);
		itemDB.setHydration(driveId, id, "O");
		// As the engine: the removed backing file is reported as deleted
		notifyBackingChange("./" ~ itemDB.computePath(driveId, id), OnDemandChangeKind.deleted);
		return true;
	}

	void pin(string driveId, string id)
	{
		hydrate(driveId, id);
		lock.lock();
		scope(exit) lock.unlock();
		itemDB.setHydration(driveId, id, "P");
	}

	void unpin(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		if (stateLocked(driveId, id) != HydrationState.pinned)
			return;
		Item item;
		itemDB.selectById(driveId, id, item);
		bool absent = item.type == ItemType.file && !exists(targetOf(driveId, id));
		itemDB.setHydration(driveId, id, absent ? "O" : "H");
	}

	/* Open handles through the mount (engine R1): cheap, never throw; while
	   an item is open dehydrate() and a single-file free throw EBUSY */
	void noteOpen(string driveId, string id, bool onAccessScanner = false)
	{
		lock.lock();
		scope(exit) lock.unlock();
		openCount[key(driveId, id)] = openCount.get(key(driveId, id), 0) + 1;
		if (onAccessScanner) scannerCount[key(driveId, id)] = scannerCount.get(key(driveId, id), 0) + 1;
		stubLog("STUB noteOpen ", id, " ", openCount[key(driveId, id)], onAccessScanner ? " scanner" : "");
	}

	void noteClose(string driveId, string id, bool onAccessScanner = false)
	{
		lock.lock();
		scope(exit) lock.unlock();
		auto k = key(driveId, id);
		if (openCount.get(k, 0) == 0)
		{
			stubLog("STUB noteClose UNBALANCED ", id);
			return;
		}
		if (onAccessScanner && scannerCount.get(k, 0) > 0 && --scannerCount[k] == 0) scannerCount.remove(k);
		if (--openCount[k] == 0) { openCount.remove(k); scannerCount.remove(k); }
		bool changeFirst;
		string rel = "./" ~ itemDB.computePath(driveId, id);
		synchronized (historyLock) changeFirst = (rel in pushedPaths) !is null;
		stubLog("STUB noteClose ", id, " ", openCount.get(k, 0), " change-already-queued=", changeFirst);
		// The engine re-evaluates a deferred online change on the last close
		if (k !in openCount && k in deferred)
		{
			deferred.remove(k);
			stubLog("STUB reevaluate deferred ", id);
		}
	}

	private bool isOpen(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		return openCount.get(key(driveId, id), 0) > 0;
	}

	/* As the real service: a free waits up to 5 s while only on-access scanners hold the file */
	private bool openOnlyByScanners(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		auto k = key(driveId, id);
		return openCount.get(k, 0) > 0 && scannerCount.get(k, 0) >= openCount[k];
	}

	private void waitForScanners(string driveId, string id)
	{
		import core.thread : Thread;
		import core.time : MonoTime, dur;
		auto deadline = MonoTime.currTime + dur!"msecs"(5000);
		bool waited;
		while (isOpen(driveId, id) && openOnlyByScanners(driveId, id) && MonoTime.currTime < deadline)
		{
			waited = true;
			Thread.sleep(dur!"msecs"(100));
		}
		if (waited) stubLog("STUB free waited for scanner ", id, isOpen(driveId, id) ? " still open" : " closed");
	}

	/* Iteration 3: transient sync states, deferred online changes, web URL */
	void setTransientForTest(string driveId, string id, TransientState state)
	{
		lock.lock();
		scope(exit) lock.unlock();
		if (state == TransientState.none) transient.remove(key(driveId, id));
		else transient[key(driveId, id)] = state;
	}

	void deferForTest(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		deferred[key(driveId, id)] = true;
	}

	// Directories: syncing if any item below is, else pending, else error
	TransientState transientStateOf(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		return transientLocked(driveId, id);
	}

	private TransientState transientLocked(string driveId, string id)
	{
		auto own = transient.get(key(driveId, id), TransientState.none);
		Item item;
		if (!itemDB.selectById(driveId, id, item) || (item.type != ItemType.dir && item.type != ItemType.root))
			return own;
		bool[TransientState] seen;
		seen[own] = true;
		foreach (child; itemDB.selectChildren(driveId, id))
			seen[transientLocked(child.driveId, child.id)] = true;
		foreach (state; [TransientState.syncing, TransientState.pending, TransientState.error])
			if (state in seen) return state;
		return TransientState.none;
	}

	string webUrlOf(string driveId, string id)
	{
		Item item;
		if (!itemDB.selectById(driveId, id, item))
			throw new HydrationError(errno.ENODATA, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		stubLog("STUB webUrlOf ", id);
		if (webUrlDelayMsecs)
			Thread.sleep(dur!"msecs"(webUrlDelayMsecs));
		if (id == "f-offline")
			throw new HydrationError(errno.EIO, "offline");
		return "https://onedrive.example/" ~ driveId ~ "/" ~ id;
	}

	/* Iteration 2 action API (engine 8e826fa). Unlike the engine, file
	   download/pin and directory actions run synchronously in the caller
	   instead of on a background worker, so tests can check the result at
	   once. Refusals follow the engine. */
	void requestAction(string driveId, string id, OnDemandAction action)
	{
		lock.lock();
		bool stopped = stopping;
		lock.unlock();
		if (stopped)
			throw new HydrationError(errno.EIO, "Hydration service is shutting down");
		Item item;
		if (!itemDB.selectById(driveId, id, item))
			throw new HydrationError(errno.ENOENT, "Item is not in the local database: " ~ driveId ~ " " ~ id);
		stubLog("STUB action ", action, " ", itemDB.computePath(driveId, id));
		if (item.type != ItemType.file && item.type != ItemType.dir && item.type != ItemType.root)
			throw new HydrationError(errno.EIO, "On-demand actions are not supported for shared items");
		if (item.type == ItemType.file) {
			final switch (action)
			{
				case OnDemandAction.download: hydrate(driveId, id); break;
				case OnDemandAction.pin: pin(driveId, id); break;
				case OnDemandAction.unpin: unpin(driveId, id); break;
				case OnDemandAction.free:
					waitForScanners(driveId, id);
					if (isOpen(driveId, id))
						throw new HydrationError(errno.EBUSY, "refused to free open " ~ id);
					if (pinnedOrPinnedAncestor(driveId, id))
						throw new HydrationError(errno.EBUSY, "refused to free pinned " ~ id);
					if (stateOf(driveId, id) == HydrationState.onlineOnly) {
						// Online-only with a local file: a change not uploaded yet
						if (exists(targetOf(driveId, id)))
							throw new HydrationError(errno.EBUSY, "refused to free changed " ~ id);
						break;
					}
					if (!dehydrate(driveId, id))
						throw new HydrationError(errno.EBUSY, "refused to free " ~ id);
					break;
			}
			return;
		}
		// free: unpin the whole subtree first, then dehydrate what can be
		if (action == OnDemandAction.free) requestAction(driveId, id, OnDemandAction.unpin);
		if (action == OnDemandAction.pin) itemDB.setHydration(driveId, id, "P");
		if (action == OnDemandAction.unpin) itemDB.setHydration(driveId, id, "H");
		foreach (child; itemDB.selectChildren(driveId, id))
		{
			try requestAction(child.driveId, child.id, action);
			catch (HydrationError e) stubLog("STUB action refused ", e.msg);
		}
	}

	void shutdown()
	{
		lock.lock();
		scope(exit) lock.unlock();
		stopping = true;
		done.notifyAll();
	}
}
