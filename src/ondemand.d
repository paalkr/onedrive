// What is this module called?
module ondemand;

// What does this module require to function?
import core.stdc.errno;
import core.stdc.stdio : renamePath = rename;
import core.stdc.string : strlen;
import core.sync.mutex;
import core.sys.linux.sys.xattr : lgetxattr, llistxattr, lremovexattr, lsetxattr;
import core.sys.posix.dirent;
import core.sys.posix.fcntl;
import core.sys.posix.sys.stat;
import core.sys.posix.sys.statvfs;
import core.sys.posix.unistd;
import std.algorithm.searching : startsWith;
import std.concurrency : Tid, send;
import std.conv : octal, to;
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
 * or move to the database, the old database path is hidden here and a
 * moved path is resolved through its old database path.
 */

private enum pinXattr = "user.onedrive.pin";
private enum stateXattr = "user.onedrive.state";
private enum FUSE_CAP_ATOMIC_O_TRUNC = 1 << 3;
private enum fileMode = octal!600;
private enum dirMode = octal!700;

// One open file. fd stays -1 until an online-only file is first read or written.
private final class Handle
{
	int flags;
	int fd = -1;
	bool written;
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

	private Mutex handleLock;
	private Handle[ulong] handles;
	private ulong nextHandle = 1;

	// Local deletes and moves not yet reflected in the database
	private Mutex pendingLock;
	private bool[string] hiddenPaths;      // "./a" hides "./a" and "./a/..."
	private string[string] movedFrom;      // new "./b" -> old "./a"

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

	// Database item for a path, taking pending local deletes and moves into account
	private bool resolve(const(char)[] path, out Item item) {
		string rel = dbPath(path);
		string oldPrefix;
		string newPrefix;
		synchronized (pendingLock) {
			string applied;
			foreach (hidden, _; hiddenPaths) {
				if (!underPath(rel, hidden)) continue;
				Item stale;
				if (rawSelect(hidden, stale)) return false;
				// The engine has applied the delete or move
				applied = hidden;
				break;
			}
			if (applied.length) hiddenPaths.remove(applied);
			foreach (newPath, oldPath; movedFrom) {
				if (underPath(rel, newPath) && newPath.length > newPrefix.length) {
					newPrefix = newPath;
					oldPrefix = oldPath;
				}
			}
		}
		if (rawSelect(rel, item)) {
			if (newPrefix.length && rel == newPrefix)
				synchronized (pendingLock) movedFrom.remove(newPrefix);
			return true;
		}
		if (newPrefix.length)
			return rawSelect(oldPrefix ~ rel[newPrefix.length .. $], item);
		return false;
	}

	private void markHidden(string rel) {
		synchronized (pendingLock) hiddenPaths[rel] = true;
	}

	// A new local item at rel replaces whatever was pending there
	private void clearPending(string rel) {
		synchronized (pendingLock) {
			hiddenPaths.remove(rel);
			movedFrom.remove(rel);
		}
	}

	private bool isOnlineOnly(const ref Item item) {
		return item.type == ItemType.file
			&& hydration.stateOf(item.driveId, item.id) == HydrationState.onlineOnly;
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
		try {
			hydration.hydrate(item.driveId, item.id);
		} catch (HydrationError e) {
			addLogEntry("On-demand download failed for " ~ dbPath(path) ~ ": " ~ e.msg);
			fail(e.errnoCode ? e.errnoCode : EIO);
		}
	}

	// Creates an empty backing file for an online-only file that is truncated to 0
	private bool truncateOnlineOnly(const(char)[] path) {
		string target = backingPath(path);
		if (existsPath(target)) return false;
		Item item;
		if (!resolve(path, item) || !isOnlineOnly(item)) return false;
		int fd = core.sys.posix.fcntl.open(toStringz(target), O_WRONLY | O_CREAT | O_TRUNC, fileMode);
		check(fd);
		core.sys.posix.unistd.close(fd);
		return true;
	}

	// Handles

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

	// Operations

	override void getattr(const(char)[] path, ref stat_t st) {
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
			// Report the full allocation; st_blocks 0 makes some tools treat the file as sparse
			st.st_blocks = (st.st_size + 511) / 512;
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
		auto h = new Handle();
		h.flags = fi.flags;
		string target = backingPath(path);
		if (existsPath(target)) {
			h.fd = openBacking(path, fi.flags);
			if (fi.flags & O_TRUNC) {
				check(ftruncate(h.fd, 0));
				h.written = true;
			}
		} else {
			Item item;
			if (!resolve(path, item)) fail(ENOENT);
			if (isDirectory(item)) fail(EISDIR);
			if (!isOnlineOnly(item)) fail(ENOENT);
			if ((fi.flags & O_TRUNC) && (fi.flags & O_ACCMODE) != O_RDONLY) {
				// The old content is discarded: create an empty file instead of downloading it
				h.fd = core.sys.posix.fcntl.open(toStringz(target),
					(fi.flags & ~O_EXCL) | O_CREAT | O_TRUNC, fileMode);
				check(h.fd);
				h.written = true;
			}
		}
		addHandle(fi, h);
	}

	override void create(const(char)[] path, mode_t mode, ref fuse_file_info fi) {
		auto h = new Handle();
		h.flags = fi.flags;
		h.fd = core.sys.posix.fcntl.open(toStringz(backingPath(path)), fi.flags | O_CREAT, mode);
		check(h.fd);
		// A new file is uploaded even if nothing is written to it
		h.written = true;
		clearPending(dbPath(path));
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
		bool created = length == 0 && path !is null && truncateOnlineOnly(path);
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
		// A null path means the file was unlinked while open; the delete was already reported
		if (h.written && path !is null) emit(OnDemandChangeKind.changed, path);
	}

	override void mkdir(const(char)[] path, uint mode) {
		check(core.sys.posix.sys.stat.mkdir(toStringz(backingPath(path)), cast(mode_t) mode));
		clearPending(dbPath(path));
		emit(OnDemandChangeKind.createDir, path);
	}

	override void unlink(const(char)[] path) {
		string target = backingPath(path);
		if (existsPath(target)) {
			check(core.sys.posix.unistd.unlink(toStringz(target)));
		} else {
			// An online-only file has nothing to remove locally
			Item item;
			if (!resolve(path, item) || !isOnlineOnly(item)) fail(ENOENT);
		}
		markHidden(dbPath(path));
		emit(OnDemandChangeKind.deleted, path);
	}

	override void rmdir(const(char)[] path) {
		stat_t st;
		getattr(path, st);
		if ((st.st_mode & S_IFMT) != S_IFDIR) fail(ENOTDIR);
		// Online-only children keep the directory non-empty
		if (listNames(path).length) fail(ENOTEMPTY);
		string target = backingPath(path);
		if (existsPath(target)) check(core.sys.posix.unistd.rmdir(toStringz(target)));
		markHidden(dbPath(path));
		emit(OnDemandChangeKind.deleted, path);
	}

	override void rename(const(char)[] orig, const(char)[] dest, uint flags) {
		enum RENAME_NOREPLACE = 1;
		if (flags & ~RENAME_NOREPLACE) fail(EINVAL);
		if (flags & RENAME_NOREPLACE) {
			stat_t st;
			bool destExists = true;
			try getattr(dest, st);
			catch (FuseException e) destExists = false;
			if (destExists) fail(EEXIST);
		}
		// The engine uploads a move from the new local path, so it must exist on disk
		hydrateIfNeeded(orig);
		check(renamePath(toStringz(backingPath(orig)), toStringz(backingPath(dest))));
		string oldRel = dbPath(orig);
		string newRel = dbPath(dest);
		synchronized (pendingLock) {
			hiddenPaths.remove(newRel);
			// A move of something that was itself moved resolves to the original
			string source = oldRel;
			if (auto p = oldRel in movedFrom) {
				source = *p;
				movedFrom.remove(oldRel);
			}
			movedFrom[newRel] = source;
			hiddenPaths[oldRel] = true;
		}
		emit(OnDemandChangeKind.moved, dest, orig);
	}

	override void utimens(const(char)[] path, const(timespec)[] tv, fuse_file_info* fi) {
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

	private string stateName(const(char)[] path, out Item item) {
		if (!resolve(path, item) || item.type != ItemType.file) return null;
		final switch (hydration.stateOf(item.driveId, item.id)) {
			case HydrationState.pinned: return "pinned";
			case HydrationState.hydrated: return "hydrated";
			case HydrationState.onlineOnly:
				// Replaced locally (O_TRUNC) and not yet uploaded
				return existsPath(backingPath(path)) ? "hydrated" : "online-only";
		}
	}

	override const(ubyte)[] getxattr(const(char)[] path, const(char)[] name) {
		if (name == stateXattr || name == pinXattr) {
			Item item;
			string state = stateName(path, item);
			if (state is null) fail(ENODATA);
			if (name == pinXattr) return cast(const(ubyte)[]) (state == "pinned" ? "1" : "0");
			return cast(const(ubyte)[]) state;
		}
		string target = backingPath(path);
		if (!existsPath(target)) fail(ENODATA);
		auto size = lgetxattr(toStringz(target), toStringz(name), null, 0);
		if (size == -1) fail(errno);
		auto value = new ubyte[size];
		size = lgetxattr(toStringz(target), toStringz(name), value.ptr, value.length);
		if (size == -1) fail(errno);
		return value[0 .. size];
	}

	override void setxattr(const(char)[] path, const(char)[] name, in ubyte[] value, int flags) {
		if (name == stateXattr) fail(EPERM);
		if (name == pinXattr) {
			Item item;
			if (stateName(path, item) is null) fail(ENOTSUP);
			auto v = cast(const(char)[]) value;
			try {
				if (v == "1") hydration.pin(item.driveId, item.id);
				else if (v == "0") hydration.unpin(item.driveId, item.id);
				else fail(EINVAL);
			} catch (HydrationError e) {
				addLogEntry("On-demand pin failed for " ~ dbPath(path) ~ ": " ~ e.msg);
				fail(e.errnoCode ? e.errnoCode : EIO);
			}
			return;
		}
		string target = backingPath(path);
		if (!existsPath(target)) fail(ENOTSUP);
		check(lsetxattr(toStringz(target), toStringz(name), value.ptr, value.length, flags));
	}

	override string[] listxattr(const(char)[] path) {
		string[] names;
		Item item;
		if (stateName(path, item) !is null) names = [pinXattr, stateXattr];
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
		if (name == stateXattr || name == pinXattr) fail(EPERM);
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
	mount.start(fs, "onedrive", mountPoint, ["fsname=onedrive", "subtype=onedrive", "default_permissions"]);
	activeFs = fs;
	activeMount = mount;
	addLogEntry("On-demand filesystem mounted: " ~ mountPoint);
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
