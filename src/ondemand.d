// What is this module called?
module ondemand;

// What does this module require to function?
import core.stdc.errno;
import core.stdc.stdio : renamePath = rename;
import core.stdc.string : strlen;
import core.sync.mutex;
import core.thread : Thread;
import core.time : MonoTime, dur;
import core.sys.linux.sys.xattr : lgetxattr, llistxattr, lremovexattr, lsetxattr;
import core.sys.posix.dirent;
import core.sys.posix.fcntl;
import core.sys.posix.sys.stat;
import core.sys.posix.sys.statvfs;
import core.sys.posix.unistd;
import std.algorithm.searching : endsWith, startsWith;
import std.concurrency : Tid, send;
import std.conv : octal, to;
import std.path : baseName, dirName;
import std.string : toStringz, fromStringz;

// What other modules that we have created do we need to import?
import fused.fuse;
import hydration;
import itemdb;
import log;

/*
 * Files On-Demand view of the sync directory, see ondemand/CONTRACT.md.
 *
 * FUSE paths ("/a/b") map to database paths ("./a/b") and to backing paths
 * (backingDir ~ "/a/b"). A file that exists in the backing dir is served
 * from there. An online-only file exists only in the database; it is
 * listed and stat'ed from database metadata and downloaded (hydrated) on
 * the first read or write, never on open, readdir or getattr.
 *
 * Everything this layer changes in the backing dir is reported to the
 * engine as an OnDemandLocalChange. Until the engine has applied a delete
 * or move to the database, the deleted item and the old path of a moved
 * item are hidden here, and a moved path is resolved through its old
 * database path. Nothing is downloaded or created through such a
 * redirect: the engine would write it at the old database path.
 */

// How long a download or O_TRUNC waits for the engine to apply a pending move. Tests lower it.
__gshared uint onDemandPendingMoveWaitSeconds = 30;
// How long the database item replaced by a rename over it stays hidden if the engine neither
// applies the move nor writes the item. Tests lower it. Deletes and moved-away paths do not
// expire: showing them again would let a read download to the old path (see resolveSettled).
__gshared uint onDemandPendingExpirySeconds = 300;

// Most FUSE worker threads at once
enum uint onDemandMaxWorkerThreads = 64;

// What a lookup by the touch thread sees for a path, so that its system call makes the kernel
// report a change the engine already made in the backing dir
private struct Pretend {
	bool present;        // false: does not exist yet (create, mkdir, rename target)
	stat_t st;           // attributes shown while present (a deleted or moved-away entry)
	ulong seq;           // the touch that needs it; dropped once that touch has run
	MonoTime since;
}

// Backstop: a pretend entry older than this is dropped even if its touch never reported back
private enum pretendExpiry = dur!"seconds"(10);

// The database item that was at a path when it was moved away or replaced
private struct StalePath {
	string key;
	string generation;   // eTag, hash and mtime; a change means the engine has written the item since
	MonoTime since;
	bool replaced;       // the destination of a rename over it (expires), not a moved-away source
}

private struct Redirect {
	string oldPath;
	MonoTime since;
}

private string generationOf(const ref Item item) {
	return item.eTag ~ "|" ~ item.quickXorHash ~ "|" ~ item.sha256Hash ~ "|" ~ item.mtime.toISOExtString();
}

private enum pinXattr = "user.onedrive.pin";
private enum stateXattr = "user.onedrive.state";
private enum actionXattr = "user.onedrive.action";
private enum weburlXattr = "user.onedrive.weburl";
private enum FUSE_CAP_ATOMIC_O_TRUNC = 1 << 3;
private enum fileMode = octal!600;
private enum dirMode = octal!700;
// The engine's own downloads stage as "<name>.partial" inside the backing dir
private enum partialSuffix = ".partial";

// One open file. fd stays -1 until an online-only file is first read or written.
private final class Handle
{
	int flags;
	int fd = -1;
	bool written;
	// Opened by the touch thread to report a change to watchers; not a user open
	bool touch;
	// The database item reported to HydrationService.noteOpen(), closed on release
	string openDriveId;
	string openId;
}

// Thumbnailers, by full name and by the 15-character /proc/<pid>/comm truncation
private immutable string[] thumbnailerNames = [
	"gdk-pixbuf-thumbnailer", "evince-thumbnailer", "totem-video-thumbnailer",
	"ffmpegthumbnailer", "gnome-thumbnailer", "tumblerd",
	"gdk-pixbuf-thum", "evince-thumbnai", "totem-video-thu", "ffmpegthumbnail",
	"ffmpegthumbnai", "gnome-thumbnai",
];

// Is the process that sent the current FUSE request a thumbnailer? pid 0 (not visible in our
// pid namespace) or an unreadable /proc entry counts as not a thumbnailer.
private string thumbnailerCaller() {
	import c.fuse.fuse : fuse_get_context;
	import std.file : readLink, readText;
	import std.string : strip;
	auto context = fuse_get_context();
	if (context is null || context.pid <= 0) return null;
	string proc = "/proc/" ~ to!string(context.pid);
	string[] names;
	try names ~= readText(proc ~ "/comm").strip; catch (Exception e) {}
	// comm can be changed by the process and is truncated; the executable is the backstop
	try names ~= baseName(readLink(proc ~ "/exe")).chompDeleted; catch (Exception e) {}
	foreach (name; names)
		foreach (known; thumbnailerNames)
			if (name == known) return name;
	return null;
}

// readlink of /proc/<pid>/exe appends " (deleted)" when the binary was replaced
private string chompDeleted(string name) {
	enum suffix = " (deleted)";
	return name.endsWith(suffix) ? name[0 .. $ - suffix.length] : name;
}

final class OnDemandFs : Operations
{
	alias open = Operations.open;
	alias release = Operations.release;
	alias read = Operations.read;
	alias write = Operations.write;
	alias truncate = Operations.truncate;
	alias utimens = Operations.utimens;
	alias initialize = Operations.initialize;

	private ItemDatabase itemDB;
	private HydrationService hydration;
	private OnDemandChangeQueue changes;
	private Tid mainTid;
	private string backingDir;
	private string rootDriveId;
	private string rootId;

	private Mutex thumbnailLogLock;
	private bool[string] thumbnailRefusalLogged;

	// Reporting changes made behind the mount's back (notifyBackingChange)
	private BackgroundFuse mount;
	private Mutex touchLock;
	private Pretend[string] pretend;       // "/a/b" -> what the touch thread's lookup sees

	private Mutex handleLock;
	private Handle[ulong] handles;
	private ulong nextHandle = 1;

	// Local deletes and moves not yet reflected in the database
	private Mutex pendingLock;
	private bool[string] deletedItems;      // item key of a local delete
	private StalePath[string] stalePaths;   // "./a" -> the item there before a move away or over it
	private Redirect[string] movedFrom;     // new "./b" -> old "./a"

	this(ItemDatabase itemDB, HydrationService hydration, OnDemandChangeQueue changes,
			Tid mainTid, string backingDir, string rootDriveId, string rootId) {
		this.itemDB = itemDB;
		this.hydration = hydration;
		this.changes = changes;
		this.mainTid = mainTid;
		this.backingDir = backingDir;
		this.rootDriveId = rootDriveId;
		this.rootId = rootId;
		handleLock = new Mutex();
		pendingLock = new Mutex();
		thumbnailLogLock = new Mutex();
		touchLock = new Mutex();
	}

	override void initialize(ref fuse_conn_info conn, ref fuse_config cfg) {
		// Unlink of an open file must unlink, not rename to .fuse_hidden*
		cfg.hard_remove = 1;
		// O_TRUNC arrives with open(), not as a separate truncate that would hydrate
		if (conn.capable & FUSE_CAP_ATOMIC_O_TRUNC) conn.want |= FUSE_CAP_ATOMIC_O_TRUNC;
	}

	override void exception(Exception e) {
		addLogEntry("ERROR: On-demand filesystem: " ~ e.msg);
	}

	// Path helpers

	private static string dbPath(const(char)[] path) {
		return path == "/" ? "." : "." ~ path.idup;
	}

	private string backingPath(const(char)[] path) {
		return path == "/" ? backingDir : backingDir ~ path.idup;
	}

	private static bool underPath(string path, string prefix) {
		return path == prefix || path.startsWith(prefix ~ "/");
	}

	private bool rawSelect(string rel, out Item item) {
		if (rel == ".") return itemDB.selectById(rootDriveId, rootId, item);
		return itemDB.selectByPath(rel, rootDriveId, item);
	}

	private static string itemKey(const ref Item item) {
		return item.driveId ~ "/" ~ item.id;
	}

	// Caller holds pendingLock. Is item a locally deleted or moved-away/replaced item that the engine has not applied yet?
	private bool isStale(string rel, const ref Item item, bool viaRedirect) {
		string k = itemKey(item);
		if (k in deletedItems) {
			Item current;
			if (itemDB.selectById(item.driveId, item.id, current)) return true;
			deletedItems.remove(k);
		}
		// The old path of a redirect is stale by construction; only deletes apply there
		if (viaRedirect) return false;
		string[] applied;
		bool stale = false;
		foreach (path, entry; stalePaths) {
			if (!underPath(rel, path)) continue;
			Item current;
			if (rawSelect(path, current) && itemKey(current) == entry.key && generationOf(current) == entry.generation) stale = true;
			// The engine has applied it, written the item since (it treated the move as a
			// change of the destination), or something else is there now
			else applied ~= path;
		}
		foreach (path; applied) stalePaths.remove(path);
		return stale;
	}

	// Database item for a path, taking pending local deletes and moves into account.
	// redirected is set when the item was found through a pending move, i.e. the
	// database still has it at its old path.
	private bool resolve(const(char)[] path, out Item item, out bool redirected) {
		string rel = dbPath(path);
		synchronized (pendingLock) {
			expirePending();
			string oldPrefix;
			string newPrefix;
			foreach (newPath, redirect; movedFrom) {
				if (underPath(rel, newPath) && newPath.length > newPrefix.length) {
					newPrefix = newPath;
					oldPrefix = redirect.oldPath;
				}
			}
			if (rawSelect(rel, item) && !isStale(rel, item, false)) {
				// The engine has applied the move
				if (newPrefix.length && rel == newPrefix) movedFrom.remove(newPrefix);
				return true;
			}
			if (newPrefix.length) {
				string oldRel = oldPrefix ~ rel[newPrefix.length .. $];
				if (rawSelect(oldRel, item) && !isStale(oldRel, item, true)) {
					redirected = true;
					return true;
				}
			}
			item = Item.init;
			return false;
		}
	}

	private bool resolve(const(char)[] path, out Item item) {
		bool redirected;
		return resolve(path, item, redirected);
	}

	// resolve() for downloads and O_TRUNC: waits (bounded) until a pending move covering
	// the path is applied, so the engine writes the file where the mount shows it
	private bool resolveSettled(const(char)[] path, out Item item) {
		auto deadline = MonoTime.currTime + dur!"seconds"(onDemandPendingMoveWaitSeconds);
		while (true) {
			bool redirected;
			if (!resolve(path, item, redirected)) return false;
			if (!redirected) return true;
			if (MonoTime.currTime >= deadline) {
				addLogEntry("On-demand: move to " ~ dbPath(path) ~ " not applied yet, refusing to download through it");
				fail(EAGAIN);
			}
			Thread.sleep(dur!"msecs"(100));
		}
	}

	// Caller holds pendingLock. Stops hiding a database item replaced by a rename over it when
	// the engine has done nothing with it within onDemandPendingExpirySeconds.
	private void expirePending() {
		auto cutoff = MonoTime.currTime - dur!"seconds"(onDemandPendingExpirySeconds);
		string[] expired;
		foreach (path, entry; stalePaths) if (entry.replaced && entry.since < cutoff) expired ~= path;
		foreach (path; expired) {
			stalePaths.remove(path);
			addLogEntry("On-demand: rename over " ~ path ~ " not processed by the engine in time, showing its database item again");
		}
	}

	private void markDeleted(const ref Item item) {
		synchronized (pendingLock) deletedItems[itemKey(item)] = true;
	}

	// A new local item at rel replaces a pending redirect there
	private void clearPending(string rel) {
		synchronized (pendingLock) movedFrom.remove(rel);
	}

	// A "<name>.partial" backing entry that is an engine download in progress, not a user file
	private bool isEnginePartial(const(char)[] path) {
		if (!path.endsWith(partialSuffix)) return false;
		Item item;
		return !rawSelect(dbPath(path), item);
	}

	// Drive of the nearest ancestor directory of path that is in the database
	private string parentDriveOf(const(char)[] path) {
		const(char)[] parent = dirName(path);
		while (true) {
			Item item;
			if (resolve(parent, item)) {
				if (item.type == ItemType.remote && item.remoteDriveId.length) return item.remoteDriveId;
				return item.driveId;
			}
			if (parent == "/") return rootDriveId;
			parent = dirName(parent);
		}
	}

	private bool isOnlineOnly(const ref Item item) {
		if (item.type != ItemType.file) return false;
		try {
			return hydration.stateOf(item.driveId, item.id) == HydrationState.onlineOnly;
		} catch (HydrationError e) {
			// Removed from the database since it was resolved
			return false;
		}
	}

	private static bool isDirectory(const ref Item item) {
		return item.type == ItemType.dir || item.type == ItemType.root || item.type == ItemType.remote;
	}

	private static bool lstatPath(string path, out stat_t st) {
		return lstat(toStringz(path), &st) == 0;
	}

	private static bool existsPath(string path) {
		stat_t st;
		return lstatPath(path, st);
	}

	private static void fail(int code) {
		throw new FuseException(code);
	}

	private static void check(int result) {
		if (result == -1) fail(errno);
	}

	private void emit(OnDemandChangeKind kind, const(char)[] path, const(char)[] oldPath = null) {
		changes.push(OnDemandLocalChange(kind, dbPath(path), oldPath is null ? null : dbPath(oldPath)));
		send(mainTid, OnDemandWake());
	}

	// Downloads path if it is an online-only file without a backing file
	private void hydrateIfNeeded(const(char)[] path) {
		if (existsPath(backingPath(path))) return;
		Item item;
		if (!resolve(path, item)) fail(ENOENT);
		if (!isOnlineOnly(item)) return;
		if (!resolveSettled(path, item)) fail(ENOENT);
		if (existsPath(backingPath(path)) || !isOnlineOnly(item)) return;
		// Thumbnails for online-only files come from OneDrive; never download a file to draw one
		string thumbnailer = thumbnailerCaller();
		if (thumbnailer !is null) {
			bool first;
			synchronized (thumbnailLogLock) {
				first = (itemKey(item) in thumbnailRefusalLogged) is null;
				thumbnailRefusalLogged[itemKey(item)] = true;
			}
			if (first) addLogEntry("On-demand: not downloading " ~ dbPath(path) ~ " for thumbnailer " ~ thumbnailer);
			fail(EIO);
		}
		try {
			hydration.hydrate(item.driveId, item.id);
		} catch (HydrationError e) {
			addLogEntry("On-demand download failed for " ~ dbPath(path) ~ ": " ~ e.msg);
			fail(e.errnoCode ? e.errnoCode : EIO);
		}
	}

	// Creates the empty backing file of an online-only file whose content is discarded
	// (O_TRUNC, truncate to 0) instead of downloading it. False if path is not an
	// online-only file without a backing file (any more); the caller then takes its normal path.
	private bool createEmptyOnlineOnly(const(char)[] path) {
		if (existsPath(backingPath(path))) return false;
		Item item;
		if (!resolve(path, item) || !isOnlineOnly(item)) return false;
		if (!resolveSettled(path, item)) return false;
		try {
			return hydration.createEmpty(item.driveId, item.id);
		} catch (HydrationError e) {
			fail(e.errnoCode ? e.errnoCode : EIO);
			assert(0);
		}
	}

	// Handles

	// Tells HydrationService that a database file is open, so "free" leaves it alone.
	// Called last in open/create, when nothing can fail any more; release() closes it.
	private void noteOpened(const(char)[] path, Handle h) {
		Item item;
		if (!resolve(path, item) || item.type != ItemType.file) return;
		try {
			hydration.noteOpen(item.driveId, item.id);
		} catch (HydrationError e) {
			// Removed from the database since it was resolved
			return;
		}
		h.openDriveId = item.driveId;
		h.openId = item.id;
	}

	private Handle handleOf(ref fuse_file_info fi) {
		synchronized (handleLock) {
			auto h = fi.fh in handles;
			if (h is null) fail(EBADF);
			return *h;
		}
	}

	private void addHandle(ref fuse_file_info fi, Handle h) {
		synchronized (handleLock) {
			fi.fh = nextHandle++;
			handles[fi.fh] = h;
		}
	}

	private int openBacking(const(char)[] path, int flags) {
		int fd = core.sys.posix.fcntl.open(toStringz(backingPath(path)), flags & ~(O_CREAT | O_EXCL | O_TRUNC));
		check(fd);
		return fd;
	}

	// The backing fd of a handle, downloading the file first if needed
	private int fdOf(const(char)[] path, Handle h) {
		synchronized (h) {
			if (h.fd == -1) {
				if (path is null) fail(ENOENT);
				hydrateIfNeeded(path);
				h.fd = openBacking(path, h.flags);
			}
			return h.fd;
		}
	}

	// Changes made behind the mount's back

	// Is the current request from the touch thread? The kernel reports the calling thread's
	// id (verified on 7.0), so nothing else, not even another thread of this process, matches.
	private bool isTouchRequest() {
		import c.fuse.fuse : fuse_get_context;
		if (mount is null) return false;
		auto context = fuse_get_context();
		if (context is null || context.pid <= 0) return false;
		return context.pid == mount.notifierTid();
	}

	private void endPretend(const(char)[] path) {
		synchronized (touchLock) pretend.remove(path.idup);
	}

	// Caller holds touchLock. Drops entries whose touch has run (whether or not the kernel
	// asked us: it may answer mkdir with EEXIST or O_CREAT with an open from a dentry it
	// cached again) or that are too old.
	private void purgePretendLocked() {
		ulong completed = mount.completedTouches();
		auto cutoff = MonoTime.currTime - pretendExpiry;
		string[] done;
		foreach (path, entry; pretend)
			if (entry.seq <= completed || entry.since < cutoff) done ~= path;
		foreach (path; done) pretend.remove(path);
	}

	private stat_t presentAs(string mountPath, bool isDirectory) {
		stat_t st;
		if (lstatPath(backingPath(mountPath), st)) return st;
		st.st_mode = isDirectory ? S_IFDIR | dirMode : S_IFREG | fileMode;
		st.st_nlink = isDirectory ? 2 : 1;
		st.st_uid = getuid();
		st.st_gid = getgid();
		return st;
	}

	private bool touchQueueFullLogged;

	// Caller holds touchLock. Queues a touch; pretends are the entries it needs
	private void queueTouchLocked(Touch kind, string path, string oldPath, long mtime,
			string backingCheck, Pretend[string] pretends) {
		auto now = MonoTime.currTime;
		// Recorded before the touch can run; its seq is known only once it is queued
		foreach (p, entry; pretends) {
			entry.seq = ulong.max;
			entry.since = now;
			pretend[p] = entry;
		}
		bool dropped;
		ulong seq = mount.queueTouch(kind, path, oldPath, mtime, backingCheck, dropped);
		foreach (p, _; pretends) {
			if (seq == 0) pretend.remove(p);
			else pretend[p].seq = seq;
		}
		if (dropped && !touchQueueFullLogged) {
			addLogEntry("On-demand: more than " ~ to!string(BackgroundFuse.maxQueuedTouches)
				~ " file manager notifications queued, dropping the oldest");
			touchQueueFullLogged = true;
		} else if (!dropped) {
			touchQueueFullLogged = false;
		}
	}

	// See notifyBackingChange()
	void backingChanged(string path, OnDemandChangeKind kind, string oldPath, bool isDirectory) {
		if (mount is null) return;
		static string mountPath(string rel) {
			if (rel == "." || rel == "./") return "/";
			return rel.startsWith("./") ? rel[1 .. $] : "/" ~ rel;
		}
		string p = mountPath(path);
		if (p == "/") return;
		stat_t st;
		bool exists = lstatPath(backingPath(p), st);
		bool dir = exists ? (st.st_mode & S_IFMT) == S_IFDIR : isDirectory;
		// Freed (dehydrated) or not downloaded: the file is gone from the backing dir but still
		// in the mount as online-only; report a change, not a delete
		stat_t visible;
		bool stillShown = false;
		if (kind == OnDemandChangeKind.deleted && !exists) {
			stillShown = true;
			try getattr(p, visible);
			catch (FuseException e) stillShown = false;
		}
		synchronized (touchLock) {
			purgePretendLocked();
			final switch (kind) {
				case OnDemandChangeKind.changed:
				case OnDemandChangeKind.createDir:
					if (!exists) return;
					if (dir) {
						queueTouchLocked(Touch.mkdir, p, null, 0, null, [p: Pretend(false)]);
					} else {
						// Reported as created, which a file manager also takes as "reload this
						// file", then with its attributes so a replaced file shows its new size
						queueTouchLocked(Touch.create, p, null, 0, null, [p: Pretend(false)]);
						queueTouchLocked(Touch.attrib, p, null, st.st_mtime, null, null);
					}
					break;
				case OnDemandChangeKind.deleted:
					if (exists) return;
					if (stillShown) {
						queueTouchLocked(Touch.attrib, p, null, visible.st_mtime, null, null);
						break;
					}
					queueTouchLocked(dir ? Touch.rmdir : Touch.unlink, p, null, 0, backingPath(p),
						[p: Pretend(true, presentAs(p, isDirectory))]);
					break;
				case OnDemandChangeKind.moved:
					if (!exists || oldPath is null) return;
					string o = mountPath(oldPath);
					queueTouchLocked(Touch.rename, p, o, 0, null, [o: Pretend(true, st), p: Pretend(false)]);
					// The kernel keeps the attributes it was shown for the old name; refresh them
					if (!dir) queueTouchLocked(Touch.attrib, p, null, st.st_mtime, null, null);
					break;
			}
		}
	}

	// Operations

	override void getattr(const(char)[] path, ref stat_t st) {
		if (isTouchRequest()) {
			Pretend p;
			bool found;
			synchronized (touchLock) {
				purgePretendLocked();
				if (auto q = path in pretend) {
					p = *q;
					found = true;
				}
			}
			if (found) {
				if (!p.present) fail(ENOENT);
				st = p.st;
				return;
			}
		}
		if (isEnginePartial(path)) fail(ENOENT);
		if (lstatPath(backingPath(path), st)) {
			// A backing file whose database path is hidden was recreated locally
			return;
		}
		Item item;
		if (!resolve(path, item)) fail(ENOENT);
		st = stat_t.init;
		st.st_uid = getuid();
		st.st_gid = getgid();
		st.st_mtime = item.mtime.toUnixTime();
		st.st_ctime = st.st_mtime;
		st.st_atime = st.st_mtime;
		st.st_blksize = 4096;
		if (isDirectory(item)) {
			st.st_mode = S_IFDIR | dirMode;
			st.st_nlink = 2;
		} else if (isOnlineOnly(item)) {
			st.st_mode = S_IFREG | fileMode;
			st.st_nlink = 1;
			st.st_size = item.size.length ? item.size.to!long : 0;
			// Nothing is stored locally, so du shows real local usage
			st.st_blocks = 0;
		} else {
			// Hydrated or pinned in the database but gone from the backing dir: deleted locally
			fail(ENOENT);
		}
	}

	override bool access(const(char)[] path, int mode) {
		stat_t st;
		getattr(path, st);
		return true;
	}

	// Names visible in a directory: backing entries plus database children
	private string[] listNames(const(char)[] path) {
		string[] names;
		bool[string] seen;

		auto dir = opendir(toStringz(backingPath(path)));
		if (dir !is null) {
			scope(exit) closedir(dir);
			for (auto entry = core.sys.posix.dirent.readdir(dir); entry !is null; entry = core.sys.posix.dirent.readdir(dir)) {
				string name = fromStringz(entry.d_name.ptr).idup;
				if (name == "." || name == "..") continue;
				if (name.endsWith(partialSuffix) && isEnginePartial((path == "/" ? "" : path) ~ "/" ~ name)) continue;
				seen[name] = true;
				names ~= name;
			}
		}

		Item parent;
		if (resolve(path, parent) && isDirectory(parent)) {
			string parentPath = path == "/" ? "" : path.idup;
			string driveId = parent.type == ItemType.remote ? parent.remoteDriveId : parent.driveId;
			string id = parent.type == ItemType.remote ? parent.remoteId : parent.id;
			foreach (child; itemDB.selectChildren(driveId, id)) {
				if (child.name in seen) continue;
				// Only what getattr would also find
				Item visible;
				if (!resolve(parentPath ~ "/" ~ child.name, visible)) continue;
				if (!isDirectory(visible) && !isOnlineOnly(visible)) continue;
				seen[child.name] = true;
				names ~= child.name;
			}
		} else if (dir is null) {
			fail(ENOENT);
		}
		return names;
	}

	override string[] readdir(const(char)[] path) {
		stat_t st;
		getattr(path, st);
		if ((st.st_mode & S_IFMT) != S_IFDIR) fail(ENOTDIR);
		return [".", ".."] ~ listNames(path);
	}

	override void open(const(char)[] path, ref fuse_file_info fi) {
		if (isEnginePartial(path)) fail(ENOENT);
		auto h = new Handle();
		h.flags = fi.flags;
		if (isTouchRequest()) {
			// A touch create answered from a dentry the kernel cached again: no side effects
			h.touch = true;
			h.fd = core.sys.posix.fcntl.open(toStringz(backingPath(path)), O_RDONLY | O_NOFOLLOW);
			if (h.fd == -1) fail(ENOENT);
			addHandle(fi, h);
			return;
		}
		bool truncating = (fi.flags & O_TRUNC) && (fi.flags & O_ACCMODE) != O_RDONLY;
		if (!existsPath(backingPath(path))) {
			Item item;
			if (!resolve(path, item)) fail(ENOENT);
			if (isDirectory(item)) fail(EISDIR);
			if (!isOnlineOnly(item)) fail(ENOENT);
			if (!truncating) {
				// Downloaded on the first read or write
				noteOpened(path, h);
				addHandle(fi, h);
				return;
			}
			// The old content is discarded: an empty file instead of a download. If the state
			// changed meanwhile (hydrated by another caller) the backing file is truncated below.
			if (!createEmptyOnlineOnly(path)) hydrateIfNeeded(path);
		}
		h.fd = openBacking(path, fi.flags);
		scope(failure) core.sys.posix.unistd.close(h.fd);
		if (fi.flags & O_TRUNC) {
			check(ftruncate(h.fd, 0));
			h.written = true;
		}
		noteOpened(path, h);
		addHandle(fi, h);
	}

	override void create(const(char)[] path, mode_t mode, ref fuse_file_info fi) {
		auto h = new Handle();
		h.flags = fi.flags;
		if (isTouchRequest()) {
			// The file is already in the backing dir; this open only makes the kernel report it.
			// Never create one: a touch that outlived its file must not leave an empty file
			// behind for the engine to upload.
			endPretend(path);
			h.touch = true;
			h.fd = core.sys.posix.fcntl.open(toStringz(backingPath(path)), O_RDONLY | O_NOFOLLOW);
			if (h.fd == -1) fail(EIO);
			addHandle(fi, h);
			return;
		}
		if (path.endsWith(partialSuffix)) fail(EINVAL);
		h.fd = core.sys.posix.fcntl.open(toStringz(backingPath(path)), fi.flags | O_CREAT, mode);
		check(h.fd);
		// A new file is uploaded even if nothing is written to it
		h.written = true;
		clearPending(dbPath(path));
		noteOpened(path, h);
		addHandle(fi, h);
	}

	override ulong read(const(char)[] path, ubyte[] buf, ulong offset, ref fuse_file_info fi) {
		int fd = fdOf(path, handleOf(fi));
		size_t done = 0;
		while (done < buf.length) {
			auto n = pread(fd, buf.ptr + done, buf.length - done, cast(off_t) (offset + done));
			if (n == -1) {
				if (errno == EINTR) continue;
				fail(errno);
			}
			if (n == 0) break;
			done += n;
		}
		return done;
	}

	override int write(const(char)[] path, in ubyte[] data, ulong offset, ref fuse_file_info fi) {
		auto h = handleOf(fi);
		int fd = fdOf(path, h);
		size_t done = 0;
		while (done < data.length) {
			auto n = pwrite(fd, data.ptr + done, data.length - done, cast(off_t) (offset + done));
			if (n == -1) {
				if (errno == EINTR) continue;
				fail(errno);
			}
			done += n;
		}
		synchronized (h) h.written = true;
		return cast(int) done;
	}

	override void truncate(const(char)[] path, ulong length, fuse_file_info* fi) {
		bool created = length == 0 && path !is null && createEmptyOnlineOnly(path);
		if (fi !is null) {
			auto h = handleOf(*fi);
			int fd = fdOf(path, h);
			check(ftruncate(fd, cast(off_t) length));
			synchronized (h) h.written = true;
			return;
		}
		if (!created) {
			hydrateIfNeeded(path);
			check(core.sys.posix.unistd.truncate(toStringz(backingPath(path)), cast(off_t) length));
		}
		emit(OnDemandChangeKind.changed, path);
	}

	override void fsync(const(char)[] path, bool datasync, ref fuse_file_info fi) {
		auto h = handleOf(fi);
		synchronized (h) {
			if (h.fd != -1) check(datasync ? fdatasync(h.fd) : core.sys.posix.unistd.fsync(h.fd));
		}
	}

	override void release(const(char)[] path, ref fuse_file_info fi) {
		Handle h;
		synchronized (handleLock) {
			auto p = fi.fh in handles;
			if (p is null) return;
			h = *p;
			handles.remove(fi.fh);
		}
		synchronized (h) {
			if (h.fd != -1) core.sys.posix.unistd.close(h.fd);
			h.fd = -1;
		}
		if (h.touch) return;
		// The change first: the last noteClose lets the engine apply an online change it
		// deferred while the file was open, and it must already know about the local edit.
		// A null path means the file was unlinked while open; the delete was already reported.
		if (h.written && path !is null) emit(OnDemandChangeKind.changed, path);
		// The item recorded at open, even if it has been moved or deleted since
		if (h.openId.length) {
			try hydration.noteClose(h.openDriveId, h.openId);
			catch (HydrationError e) addLogEntry("On-demand: noteClose failed for " ~ h.openId ~ ": " ~ e.msg);
		}
	}

	override void mkdir(const(char)[] path, uint mode) {
		if (isTouchRequest()) {
			endPretend(path);
			return;
		}
		if (path.endsWith(partialSuffix)) fail(EINVAL);
		check(core.sys.posix.sys.stat.mkdir(toStringz(backingPath(path)), cast(mode_t) mode));
		clearPending(dbPath(path));
		emit(OnDemandChangeKind.createDir, path);
	}

	override void unlink(const(char)[] path) {
		if (isTouchRequest()) {
			endPretend(path);
			return;
		}
		string target = backingPath(path);
		Item item;
		bool inDatabase = resolve(path, item);
		if (existsPath(target)) {
			check(core.sys.posix.unistd.unlink(toStringz(target)));
		} else {
			// An online-only file has nothing to remove locally
			if (!inDatabase || !isOnlineOnly(item)) fail(ENOENT);
		}
		if (inDatabase) markDeleted(item);
		emit(OnDemandChangeKind.deleted, path);
	}

	override void rmdir(const(char)[] path) {
		if (isTouchRequest()) {
			endPretend(path);
			return;
		}
		stat_t st;
		getattr(path, st);
		if ((st.st_mode & S_IFMT) != S_IFDIR) fail(ENOTDIR);
		// Online-only children keep the directory non-empty
		if (listNames(path).length) fail(ENOTEMPTY);
		string target = backingPath(path);
		Item item;
		bool inDatabase = resolve(path, item);
		if (existsPath(target)) check(core.sys.posix.unistd.rmdir(toStringz(target)));
		if (inDatabase) markDeleted(item);
		emit(OnDemandChangeKind.deleted, path);
	}

	override void rename(const(char)[] orig, const(char)[] dest, uint flags) {
		if (isTouchRequest()) {
			endPretend(orig);
			endPretend(dest);
			return;
		}
		enum RENAME_NOREPLACE = 1;
		// RENAME_EXCHANGE and RENAME_WHITEOUT are not supported
		if (flags & ~RENAME_NOREPLACE) fail(EINVAL);
		if (dest.endsWith(partialSuffix)) fail(EINVAL);

		// Judge source and destination by what the mount shows, not by the backing dir:
		// a directory whose children are all online-only is empty in the backing dir
		stat_t srcSt;
		getattr(orig, srcSt);
		bool srcIsDir = (srcSt.st_mode & S_IFMT) == S_IFDIR;
		stat_t destSt;
		bool destExists = true;
		try getattr(dest, destSt);
		catch (FuseException e) {
			if (e.errno != ENOENT) throw e;
			destExists = false;
		}
		if (orig == dest) return;
		Item replaced;
		bool replacesDatabaseItem = false;
		if (destExists) {
			if (flags & RENAME_NOREPLACE) fail(EEXIST);
			bool destIsDir = (destSt.st_mode & S_IFMT) == S_IFDIR;
			if (srcIsDir && !destIsDir) fail(ENOTDIR);
			if (!srcIsDir && destIsDir) fail(EISDIR);
			if (destIsDir && listNames(dest).length) fail(ENOTEMPTY);
			replacesDatabaseItem = resolve(dest, replaced);
		}
		// A move between drives (into or out of a shared folder) is a copy and a delete
		if (parentDriveOf(orig) != parentDriveOf(dest)) fail(EXDEV);

		// The engine uploads a move from the new local path, so it must exist on disk
		if (!srcIsDir) hydrateIfNeeded(orig);
		Item moved;
		bool movesDatabaseItem = resolve(orig, moved);
		// An empty destination directory that exists only in the database has no backing dir to replace
		check(renamePath(toStringz(backingPath(orig)), toStringz(backingPath(dest))));

		string oldRel = dbPath(orig);
		string newRel = dbPath(dest);
		synchronized (pendingLock) {
			// A move of something that was itself moved resolves to the original
			string source = oldRel;
			if (auto p = oldRel in movedFrom) {
				source = p.oldPath;
				movedFrom.remove(oldRel);
			}
			auto now = MonoTime.currTime;
			if (movesDatabaseItem) {
				movedFrom[newRel] = Redirect(source, now);
				Item atOld;
				if (rawSelect(oldRel, atOld)) stalePaths[oldRel] = StalePath(itemKey(atOld), generationOf(atOld), now, false);
				// The replaced destination item stays in the database until the engine applies the move
				if (replacesDatabaseItem) stalePaths[newRel] = StalePath(itemKey(replaced), generationOf(replaced), now, true);
			} else {
				// A new local file (e.g. an editor's temp file saved over the original) has no database
				// item to redirect to: the destination item is simply overwritten and keeps its identity
				movedFrom.remove(newRel);
				stalePaths.remove(newRel);
			}
		}
		emit(OnDemandChangeKind.moved, dest, orig);
	}

	override void utimens(const(char)[] path, const(timespec)[] tv, fuse_file_info* fi) {
		// Sent by the touch thread only to make the kernel report changed attributes
		if (isTouchRequest()) return;
		hydrateIfNeeded(path);
		timespec[2] times;
		if (tv is null) times[0].tv_nsec = times[1].tv_nsec = UTIME_NOW;
		else times = tv[0 .. 2];
		check(utimensat(AT_FDCWD, toStringz(backingPath(path)), times, AT_SYMLINK_NOFOLLOW));
		if (fi !is null) {
			auto h = handleOf(*fi);
			synchronized (h) h.written = true;
		} else {
			emit(OnDemandChangeKind.changed, path);
		}
	}

	override void chmod(const(char)[] path, mode_t mode) {
		// OneDrive has no permissions to sync; keep them on the backing file only
		string target = backingPath(path);
		if (existsPath(target)) check(core.sys.posix.sys.stat.chmod(toStringz(target), mode));
		else {
			stat_t st;
			getattr(path, st);
		}
	}

	override void chown(const(char)[] path, uid_t uid, gid_t gid) {
		stat_t st;
		getattr(path, st);
	}

	override void statfs(const(char)[] path, ref statvfs_t st) {
		check(statvfs(toStringz(backingDir), &st));
	}

	// Extended attributes

	// user.onedrive.state: online-only, hydrated, pinned; local for an item not in the database
	private string stateName(const(char)[] path) {
		Item item;
		if (!resolve(path, item)) {
			stat_t st;
			getattr(path, st);   // ENOENT if the path does not exist at all
			return "local";
		}
		string driveId = item.type == ItemType.remote ? item.remoteDriveId : item.driveId;
		string id = item.type == ItemType.remote ? item.remoteId : item.id;
		// An upload or download in progress, a queued or retried change, or a failure takes
		// precedence over the stored state. The engine aggregates directories.
		TransientState transient;
		try transient = hydration.transientStateOf(driveId, id);
		catch (HydrationError e) return "local";
		final switch (transient) {
			case TransientState.syncing: return "syncing";
			case TransientState.pending: return "pending";
			case TransientState.error: return "error";
			case TransientState.none: break;
		}
		// For a directory stateOf() aggregates: pinned if it is pinned, else online-only
		// if any file below it is, else hydrated
		HydrationState state;
		try state = hydration.stateOf(driveId, id);
		catch (HydrationError e) return "local";
		if (isDirectory(item)) {
			final switch (state) {
				case HydrationState.pinned: return "pinned";
				case HydrationState.hydrated: return "hydrated";
				case HydrationState.onlineOnly: return "online-only";
			}
		}
		final switch (state) {
			case HydrationState.pinned: return "pinned";
			case HydrationState.hydrated: return "hydrated";
			case HydrationState.onlineOnly:
				// Replaced locally (O_TRUNC) and not yet uploaded
				return existsPath(backingPath(path)) ? "hydrated" : "online-only";
		}
	}

	// Runs a user.onedrive.action (or pin alias) on the item at path
	private void runAction(const(char)[] path, OnDemandAction action) {
		Item item;
		if (!resolve(path, item)) {
			stat_t st;
			getattr(path, st);
			// Not in the database yet: nothing to download or free, pinning waits for the upload
			fail(EOPNOTSUPP);
		}
		// Downloads and deletes go to the database path of the item
		if (!resolveSettled(path, item)) fail(ENOENT);
		try {
			hydration.requestAction(item.driveId, item.id, action);
		} catch (HydrationError e) {
			addLogEntry("On-demand " ~ to!string(action) ~ " failed for " ~ dbPath(path) ~ ": " ~ e.msg);
			fail(e.errnoCode ? e.errnoCode : EIO);
		}
	}

	private static bool parseAction(const(char)[] value, out OnDemandAction action) {
		import std.string : strip;
		switch (value.strip) {
			case "download": action = OnDemandAction.download; return true;
			case "pin": action = OnDemandAction.pin; return true;
			case "unpin": action = OnDemandAction.unpin; return true;
			case "free": action = OnDemandAction.free; return true;
			default: return false;
		}
	}

	override const(ubyte)[] getxattr(const(char)[] path, const(char)[] name) {
		if (name == stateXattr) return cast(const(ubyte)[]) stateName(path);
		// Compatibility alias, readable as 1/0
		if (name == pinXattr) return cast(const(ubyte)[]) (stateName(path) == "pinned" ? "1" : "0");
		// Write-only
		if (name == actionXattr) fail(ENODATA);
		if (name == weburlXattr) return cast(const(ubyte)[]) webUrl(path);
		string target = backingPath(path);
		if (!existsPath(target)) fail(ENODATA);
		auto size = lgetxattr(toStringz(target), toStringz(name), null, 0);
		if (size == -1) fail(errno);
		auto value = new ubyte[size];
		size = lgetxattr(toStringz(target), toStringz(name), value.ptr, value.length);
		if (size == -1) fail(errno);
		return value[0 .. size];
	}

	// user.onedrive.weburl: the item's OneDrive web URL. The lookup may take a network round
	// trip; it blocks only this request's worker thread (see onDemandMaxWorkerThreads).
	private string webUrl(const(char)[] path) {
		Item item;
		if (!resolve(path, item)) {
			stat_t st;
			getattr(path, st);   // ENOENT if the path does not exist at all
			fail(ENODATA);       // not uploaded yet: no URL
		}
		try {
			return hydration.webUrlOf(item.driveId, item.id);
		} catch (HydrationError e) {
			fail(e.errnoCode ? e.errnoCode : EIO);
			assert(0);
		}
	}

	override void setxattr(const(char)[] path, const(char)[] name, in ubyte[] value, int flags) {
		if (name == stateXattr || name == weburlXattr) fail(EPERM);
		auto v = cast(const(char)[]) value;
		if (name == actionXattr) {
			OnDemandAction action;
			if (!parseAction(v, action)) fail(EINVAL);
			runAction(path, action);
			return;
		}
		if (name == pinXattr) {
			if (v == "1") runAction(path, OnDemandAction.pin);
			else if (v == "0") runAction(path, OnDemandAction.unpin);
			else fail(EINVAL);
			return;
		}
		string target = backingPath(path);
		if (!existsPath(target)) fail(ENOTSUP);
		check(lsetxattr(toStringz(target), toStringz(name), value.ptr, value.length, flags));
	}

	// Lists user.onedrive.state only: action is write-only and pin a legacy alias, and
	// listing them would make "getfattr -d" fail or show a duplicate of the state.
	// weburl is not listed because reading it costs a network request.
	override string[] listxattr(const(char)[] path) {
		stat_t st;
		getattr(path, st);
		string[] names = [stateXattr];
		string target = backingPath(path);
		if (existsPath(target)) {
			auto size = llistxattr(toStringz(target), null, 0);
			if (size > 0) {
				auto buf = new char[size];
				size = llistxattr(toStringz(target), buf.ptr, buf.length);
				for (size_t i = 0; size > 0 && i < size; ) {
					auto n = strlen(buf.ptr + i);
					names ~= buf[i .. i + n].idup;
					i += n + 1;
				}
			}
		}
		return names;
	}

	override void removexattr(const(char)[] path, const(char)[] name) {
		if (name == stateXattr || name == pinXattr || name == actionXattr || name == weburlXattr) fail(EPERM);
		string target = backingPath(path);
		if (!existsPath(target)) fail(ENODATA);
		check(lremovexattr(toStringz(target), toStringz(name)));
	}
}

// Mount lifecycle, called from main.d

private __gshared BackgroundFuse activeMount;
private __gshared OnDemandFs activeFs;

// Mounts the on-demand view of backingDir on mountPoint. Throws on failure.
void startOnDemandMount(ItemDatabase itemDB, HydrationService hydration, OnDemandChangeQueue changes,
		Tid mainTid, string mountPoint, string backingDir, string rootDriveId, string rootId) {
	if (activeMount !is null && activeMount.mounted()) throw new Exception("On-demand filesystem is already mounted");
	auto fs = new OnDemandFs(itemDB, hydration, changes, mainTid, backingDir, rootDriveId, rootId);
	auto mount = new BackgroundFuse();
	fs.mount = mount;
	// Downloads and web URL lookups block their worker thread; with libfuse's default of 10
	// workers ten of them would stall every other request (ls, stat) on the mount
	mount.start(fs, "onedrive", mountPoint, ["fsname=onedrive", "subtype=onedrive", "default_permissions"], onDemandMaxWorkerThreads);
	if (!mount.startNotifier())
		addLogEntry("WARNING: On-demand: the file manager notification thread did not start; changes made by the client will not show in file managers until they reload");
	activeFs = fs;
	activeMount = mount;
	addLogEntry("On-demand filesystem mounted: " ~ mountPoint);
}

/*
 * Reports a change the engine made directly in the backing dir, so that file managers watching
 * the mount (inotify) see it: a download or re-download (changed), a new directory (createDir),
 * a delete (deleted) or a move (moved, oldPath is the old path). Paths are "./a/b" like
 * OnDemandLocalChange. Call it after the change is complete on disk; for deleted, pass
 * isDirectory for a directory. Thread-safe, never blocks, returns at once; a no-op when nothing
 * is mounted. It never produces an OnDemandLocalChange.
 *
 * The kernel sends inotify events only for system calls made through the mount, and no FUSE
 * notification produces one (ondemand/test/notify-matrix.sh), so a dedicated thread repeats the
 * change as a system call on the mount (create, mkdir, unlink, rmdir, rename, utimensat) that
 * the filesystem recognises and turns into a no-op.
 */
void notifyBackingChange(string path, OnDemandChangeKind kind, string oldPath = null, bool isDirectory = false) {
	auto fs = activeFs;
	if (fs !is null) fs.backingChanged(path, kind, oldPath, isDirectory);
}

// The active mount, for tests of the kernel notifications
BackgroundFuse onDemandMountForTest() {
	return activeMount;
}

// Unmounts. Safe to call when nothing is mounted.
void stopOnDemandMount() {
	if (activeMount is null) return;
	bool clean = activeMount.stop();
	if (!clean) addLogEntry("WARNING: On-demand filesystem did not stop within the timeout; detached it lazily");
	else addLogEntry("On-demand filesystem unmounted");
	activeMount = null;
	activeFs = null;
}
