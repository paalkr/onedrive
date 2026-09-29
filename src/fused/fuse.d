/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the Boost-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */
module fused.fuse;

/* reexport stat_t */
public import core.sys.posix.fcntl;
public import core.sys.posix.time : timespec;
public import core.sys.posix.sys.statvfs : statvfs_t;
public import c.fuse.common : fuse_file_info, fuse_conn_info;
public import c.fuse.fuse : fuse_config;

import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import std.string;
import std.process;
import errno = core.stdc.errno;
import core.stdc.string;
import core.sys.posix.signal;

import c.fuse.fuse;

import core.thread : Thread, thread_attachThis, thread_detachThis;
import core.time : dur, MonoTime;
import core.sys.posix.pthread;

/**
 * libfuse is handling the thread creation and we cannot hook into it. However
 * we need to make the GC aware of the threads. So for any call to a handler
 * we check if the current thread is attached and attach it if necessary.
 *
 * The thread is detached again from a pthread key destructor, which runs on
 * thread exit whether the thread returns or is cancelled. A pthread_cleanup
 * handler pushed here did not detach the libfuse workers, leaving dangling
 * Thread objects that crashed in pthread_detach() during runtime shutdown.
 */
private int threadAttached = false;
private __gshared pthread_key_t detachKey;
private __gshared pthread_once_t detachKeyOnce = PTHREAD_ONCE_INIT;

extern(C) void detach(void* ptr) nothrow
{
    /* Once removed from the thread list the Thread object's destructor no
       longer calls pthread_detach() on the (by then joined) handle */
    thread_detachThis();
}

extern(C) private void createDetachKey() nothrow
{
    pthread_key_create(&detachKey, &detach);
}

private void attach()
{
    if (!threadAttached)
    {
        /* Threads created by D (e.g. the main thread with -s) are already
           registered and must not be detached on exit */
        if (Thread.getThis() is null)
        {
            thread_attachThis();
            pthread_once(&detachKeyOnce, &createDetachKey);
            /* any non-null value makes the destructor run on thread exit */
            pthread_setspecific(detachKey, cast(void*) 1);
        }
        threadAttached = true;
    }
}

/**
 * A template to wrap C function calls and support exceptions to indicate
 * errors.
 *
 * The template passes the Operations object to the lambda as the first
 * argument.
 */
private auto call(alias fn)()
{
    attach();
    auto t = cast(Operations*) fuse_get_context().private_data;
    try
    {
        return fn(*t);
    }
    catch (FuseException fe)
    {
        /* errno is used to indicate an error to libfuse */
        errno.errno = fe.errno;
        return -fe.errno;
    }
    catch (Exception e)
    {
        (*t).exception(e);
        return -errno.EIO;
    }
}

/* libfuse passes a null path to release, read, write, fsync and friends
 * when the file was unlinked while open (hard_remove) */
private const(char)[] dpath(const(char)* path) nothrow
{
    return path is null ? null : path[0 .. strlen(path)];
}

/* C calling convention compatible function wrappers to hand into libfuse which wrap
 * the call to our Operations object.
 *
 * Note that we convert our * char pointer to an array using the
 * ptr[0..len] syntax.
 */
extern(System)
{
    private int dfuse_access(const char* path, int mode)
    {
        return call!(
            (Operations t)
            {
                if(t.access(dpath(path), mode))
                {
                    return 0;
                }
                return -1;
            })();
    }

    private int dfuse_getattr(const char*  path, stat_t* st, fuse_file_info* fi)
    {
        return call!(
            (Operations t)
            {
                t.getattr(dpath(path), *st);
                return 0;
            })();
    }

    private int dfuse_readdir(const char* path, void* buf,
            fuse_fill_dir_t filler, off_t offset, fuse_file_info* fi,
            fuse_readdir_flags flags)
    {
        return call!(
            (Operations t)
            {
                foreach(file; t.readdir(dpath(path)))
                {
                    filler(buf, toStringz(file), null, 0,
                        cast(fuse_fill_dir_flags) 0);
                }
                return 0;
            })();
    }

    private int dfuse_readlink(const char* path, char* buf, size_t size)
    {
        return call!(
            (Operations t)
            {
                auto length = t.readlink(dpath(path),
                    (cast(ubyte*)buf)[0..size]);
                /* Null-terminate the string and copy it over to the buffer. */
                assert(length <= size);
                buf[length] = '\0';

                return 0;
            })();
    }

    private int dfuse_open(const char* path, fuse_file_info* fi)
    {
        return call!(
            (Operations t)
            {
                t.open(dpath(path), *fi);
                return 0;
            })();
    }

    private int dfuse_release(const char* path, fuse_file_info* fi)
    {
        return call!(
            (Operations t)
            {
                t.release(dpath(path), *fi);
                return 0;
            })();
    }

    private int dfuse_read(const char* path, char* buf, size_t size,
                           off_t offset, fuse_file_info* fi)
    {
        /* Ensure at compile time that off_t and size_t fit into an ulong. */
        static assert(ulong.max >= size_t.max);
        static assert(ulong.max >= off_t.max);

        return call!(
            (Operations t)
            {
                auto bbuf = cast(ubyte*) buf;
                return cast(int) t.read(dpath(path), bbuf[0..size],
                    to!ulong(offset), *fi);
            })();
    }

    private int dfuse_write(const char* path, const char* data, size_t size,
                            off_t offset, fuse_file_info* fi)
    {
        static assert(ulong.max >= size_t.max);
        static assert(ulong.max >= off_t.max);

        return call!(
            (Operations t)
            {
                auto bdata = cast(ubyte*) data;
                return t.write(dpath(path), bdata[0..size],
                    to!ulong(offset), *fi);
            })();
    }

    private int dfuse_truncate(const char* path, off_t length, fuse_file_info* fi)
    {
        static assert(ulong.max >= off_t.max);
        return call!(
            (Operations t)
            {
                t.truncate(dpath(path), to!ulong(length), fi);
                return 0;
            })();
    }

    private int dfuse_mknod(const char* path, mode_t mod, dev_t dev)
    {
        static assert(ulong.max >= dev_t.max);
        static assert(uint.max >= mode_t.max);
        return call!(
            (Operations t)
            {
                t.mknod(dpath(path), mod, dev);
                return 0;
            })();
    }

    private int dfuse_unlink(const char* path)
    {
        return call!(
            (Operations t)
            {
                t.unlink(dpath(path));
                return 0;
            })();
    }

    private int dfuse_mkdir(const char * path, mode_t mode)
    {
        static assert(uint.max >= mode_t.max);
        return call!(
            (Operations t)
            {
                t.mkdir(dpath(path), mode.to!uint);
                return 0;
            })();
    }
    private int dfuse_rmdir(const char * path)
    {
        return call!(
            (Operations t)
            {
                t.rmdir(dpath(path));
                return 0;
            })();
    }

    private int dfuse_rename(const char* orig, const char* dest, uint flags) {
        return call!(
            (Operations t)
            {
                t.rename(orig[0..orig.strlen], dest[0..dest.strlen], flags);
                return 0;
            })();
    }

    private int dfuse_chmod(const char* path, mode_t mode, fuse_file_info* fi) {
        return call!(
            (Operations t)
            {
                t.chmod(dpath(path), mode);
                return 0;
            }
        )();
    }

    private int dfuse_utimens(const char* path, const(timespec)* tv,
            fuse_file_info* fi) {
        return call!(
            (Operations t)
            {
                /* tv is [atime, mtime]; tv_nsec may be UTIME_NOW or UTIME_OMIT */
                t.utimens(dpath(path), tv is null ? null : tv[0 .. 2], fi);
                return 0;
            }
        );
    }

    private int dfuse_symlink(const char* target, const char* link) {
        return call!(
            (Operations t)
            {
                t.symlink(target[0 .. target.strlen], link[0 .. link.strlen]);
                return 0;
            }
        );
    }

    private int dfuse_chown(const char* path, uid_t uid, gid_t gid,
            fuse_file_info* fi) {
        return call!(
            (Operations t)
            {
                t.chown(dpath(path), uid, gid);
                return 0;
            }
        );
    }

    private int dfuse_create(const char* path, mode_t mode, fuse_file_info* fi)
    {
        return call!(
            (Operations t)
            {
                t.create(dpath(path), mode, *fi);
                return 0;
            })();
    }

    private int dfuse_fsync(const char* path, int datasync, fuse_file_info* fi)
    {
        return call!(
            (Operations t)
            {
                t.fsync(dpath(path), datasync != 0, *fi);
                return 0;
            })();
    }

    private int dfuse_statfs(const char* path, statvfs_t* st)
    {
        return call!(
            (Operations t)
            {
                t.statfs(dpath(path), *st);
                return 0;
            })();
    }

    private int dfuse_setxattr(const char* path, const char* name,
            const char* value, size_t size, int flags)
    {
        return call!(
            (Operations t)
            {
                t.setxattr(dpath(path), name[0 .. name.strlen],
                    (cast(const(ubyte)*) value)[0 .. size], flags);
                return 0;
            })();
    }

    /* size 0 asks for the length only; a too small buffer is ERANGE */
    private int copyXattr(const(ubyte)[] value, char* buf, size_t size)
    {
        if (size == 0)
            return cast(int) value.length;
        if (value.length > size)
            return -errno.ERANGE;
        memcpy(buf, value.ptr, value.length);
        return cast(int) value.length;
    }

    private int dfuse_getxattr(const char* path, const char* name, char* buf,
            size_t size)
    {
        return call!(
            (Operations t)
            {
                return copyXattr(t.getxattr(dpath(path),
                    name[0 .. name.strlen]), buf, size);
            })();
    }

    private int dfuse_listxattr(const char* path, char* buf, size_t size)
    {
        return call!(
            (Operations t)
            {
                /* names are NUL separated and NUL terminated */
                ubyte[] list;
                foreach (n; t.listxattr(dpath(path)))
                    list ~= cast(const(ubyte)[]) n ~ cast(ubyte) 0;
                return copyXattr(list, buf, size);
            })();
    }

    private int dfuse_removexattr(const char* path, const char* name)
    {
        return call!(
            (Operations t)
            {
                t.removexattr(dpath(path), name[0 .. name.strlen]);
                return 0;
            })();
    }

    private void* dfuse_init(fuse_conn_info* conn, fuse_config* cfg)
    {
        attach();
        auto t = cast(Operations*) fuse_get_context().private_data;
        (*t).initialize(*conn, *cfg);
        return t;
    }

    private void dfuse_destroy(void* data)
    {
        /* libfuse worker threads detach themselves from the D runtime on
           exit (see attach()), so fuse_main() can simply return. */
    }
} /* extern(C) */

/* The callback table shared by Fuse and BackgroundFuse */
private fuse_operations makeOperations()
{
    fuse_operations fops;
    fops.init = &dfuse_init;
    fops.access = &dfuse_access;
    fops.getattr = &dfuse_getattr;
    fops.readdir = &dfuse_readdir;
    fops.open = &dfuse_open;
    fops.release = &dfuse_release;
    fops.read = &dfuse_read;
    fops.write = &dfuse_write;
    fops.truncate = &dfuse_truncate;
    fops.readlink = &dfuse_readlink;
    fops.destroy = &dfuse_destroy;
    fops.mknod = &dfuse_mknod;
    fops.unlink = &dfuse_unlink;
    fops.mkdir = &dfuse_mkdir;
    fops.rmdir = &dfuse_rmdir;
    fops.rename = &dfuse_rename;
    fops.chmod = &dfuse_chmod;
    fops.utimens = &dfuse_utimens;
    fops.symlink = &dfuse_symlink;
    fops.chown = &dfuse_chown;
    fops.create = &dfuse_create;
    fops.fsync = &dfuse_fsync;
    fops.statfs = &dfuse_statfs;
    fops.setxattr = &dfuse_setxattr;
    fops.getxattr = &dfuse_getxattr;
    fops.listxattr = &dfuse_listxattr;
    fops.removexattr = &dfuse_removexattr;
    return fops;
}

export class FuseException : Exception
{
    public int errno;
    this(int errno, string file = __FILE__, size_t line = __LINE__,
         Throwable next = null)
    {
        super("Fuse Exception", file, line, next);
        this.errno = errno;
    }
}

/**
 * An object oriented wrapper around fuse_operations.
 */
export class Operations
{
    /**
     * Runs on filesystem creation
     */
    void initialize()
    {
    }

    /**
     * Runs on filesystem creation with the connection and high-level
     * configuration, which may be adjusted (e.g. cfg.hard_remove). The
     * default calls initialize().
     */
    void initialize(ref fuse_conn_info conn, ref fuse_config cfg)
    {
        initialize();
    }

    /**
     * Called to get a stat(2) structure for a path.
     */
    void getattr(const(char)[] path, ref stat_t stat)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Read path into the provided buffer beginning at offset.
     *
     * Params:
     *   path   = The path to the file to read.
     *   buf    = The buffer to read the data into.
     *   offset = An offset to start reading at.
     * Returns: The amount of bytes read.
     */
    ulong read(const(char)[] path, ubyte[] buf, ulong offset)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /// read() with the file handle of open()/create(). Defaults to read().
    ulong read(const(char)[] path, ubyte[] buf, ulong offset,
        ref fuse_file_info fi)
    {
        return read(path, buf, offset);
    }

    /**
     * Write the given data to the file.
     *
     * Params:
     *   path   = The path to the file to write.
     *   buf    = A read-only buffer containing the data to write.
     *   offset = An offset to start writing at.
     * Returns: The amount of bytes written.
     */
    int write(const(char)[] path, in ubyte[] data, ulong offset)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /// write() with the file handle of open()/create(). Defaults to write().
    int write(const(char)[] path, in ubyte[] data, ulong offset,
        ref fuse_file_info fi)
    {
        return write(path, data, offset);
    }

    /**
     * Truncate a file to the given length.
     * Params:
     *   path   = The path to the file to truncate.
     *   length = Truncate file to this given length.
     */
    void truncate(const(char)[] path, ulong length)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * truncate() with the file handle when called for ftruncate(2) on an
     * open file, null otherwise. Defaults to truncate().
     */
    void truncate(const(char)[] path, ulong length, fuse_file_info* fi)
    {
        truncate(path, length);
    }

    /**
     * Returns a list of files and directory names in the given folder. Note
     * that you have to return . and ..
     *
     * Params:
     *   path = The path to the directory.
     * Returns: An array of filenames.
     */
    string[] readdir(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Reads the link identified by path into the given buffer.
     *
     * Params:
     *   path = The path to the directory.
     */
    size_t readlink(const(char)[] path, ubyte[] buf)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Determine if the user has access to the given path.
     *
     * Params:
     *   path = The path to check.
     *   mode = A flag indicating what to check for. See access(2) for
     *          supported modes.
     * Returns: True on success otherwise false.
     */
    bool access(const(char)[] path, int mode)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Changes the mode of a path.
     *
     * Params:
     *   path = The path to check.
     *   mode = The mode to set.
     */
    void chmod(const(char)[] path, mode_t mode)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Sets access and modification time with nanosecond resolution.
     *
     * Params:
     *   path = The path to modify.
     *   tv   = [atime, mtime], see utimensat(2) for UTIME_NOW and UTIME_OMIT.
     *          May be null.
     */
    void utimens(const(char)[] path, const(timespec)[] tv)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /// utimens() with the file handle if the file is open (may be null)
    void utimens(const(char)[] path, const(timespec)[] tv, fuse_file_info* fi)
    {
        utimens(path, tv);
    }

    /**
     * Creates a symlink.
     *
     * Params:
     *   path = The path to create.
     *   target = The target of the link.
     */
    void symlink(const(char)[] target, const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Changes ownership of a file.
     *
     * Params:
     *   path = Path to the file.
     *   uid = New user ID.
     *   gid = New group ID.
     */
    void chown(const(char)[] path, uid_t uid, gid_t gid)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void mknod(const(char)[] path, int mod, ulong dev)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void unlink(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void mkdir(const(char)[] path, uint mode)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void rmdir(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Renames a file.
     *
     * Params:
     *   orig  = The path to rename.
     *   dest  = The new path.
     *   flags = RENAME_EXCHANGE or RENAME_NOREPLACE, see rename(2). A
     *           filesystem that does not support a flag should throw
     *           FuseException(EINVAL).
     */
    void rename(const(char)[] orig, const(char)[] dest, uint flags)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void open(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * open() with the open flags (fi.flags) and room for a file handle
     * (fi.fh), passed back to read/write/release. Defaults to open().
     */
    void open(const(char)[] path, ref fuse_file_info fi)
    {
        open(path);
    }

    void release(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /// release() with the file handle of open()/create(). Defaults to release().
    void release(const(char)[] path, ref fuse_file_info fi)
    {
        release(path);
    }

    /**
     * Creates and opens a file. The default throws ENOSYS, which makes the
     * kernel fall back to mknod() and open().
     */
    void create(const(char)[] path, mode_t mode, ref fuse_file_info fi)
    {
        throw new FuseException(errno.ENOSYS);
    }

    void fsync(const(char)[] path, bool datasync, ref fuse_file_info fi)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void statfs(const(char)[] path, ref statvfs_t st)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /// Extended attributes. flags are XATTR_CREATE / XATTR_REPLACE.
    void setxattr(const(char)[] path, const(char)[] name, in ubyte[] value,
        int flags)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /// Returns the attribute value; throw ENODATA if it does not exist
    const(ubyte)[] getxattr(const(char)[] path, const(char)[] name)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /// Returns the attribute names
    string[] listxattr(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void removexattr(const(char)[] path, const(char)[] name)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void exception(Exception e)
    {
    }
}

/**
 * A wrapper around fuse_main()
 */
export class Fuse
{
private:
    bool foreground;
    bool threaded;
    string fsname;
    int pid;

public:
    this(string fsname)
    {
        this(fsname, false, true);
    }

    this(string fsname, bool foreground, bool threaded)
    {
        this.fsname = fsname;
        this.foreground = foreground;
        this.threaded = threaded;
    }

    void mount(Operations ops, const string mountpoint, string[] mountopts)
    {
        string [] args = [this.fsname];

        args ~= mountpoint;

        if(mountopts.length > 0)
        {
            args ~= format("-o%s", mountopts.join(","));
        }

        if(this.foreground)
        {
            args ~= "-f";
        }

        if(!this.threaded)
        {
            args ~= "-s";
        }

        debug writefln("fuse arguments s=(%s)", args);

        fuse_operations fops = makeOperations();

        /* Create c-style arguments from a string[] array. */
        auto cargs = array(map!(a => toStringz(a))(args));
        int length = cast(int) cargs.length;
        static if(length.max < cargs.length.max)
        {
            /* This is an unsafe cast that we need to do for C compat.
               enforce, unlike assert, will be checked in optimised builds as well. */
            import std.exception : enforce;
            enforce(length >= 0);
            enforce(length == cargs.length);
        }

        this.pid = thisProcessID();
        fuse_main(length, cast(char**) cargs.ptr, &fops, &ops);
    }

    void exit()
    {
        kill(this.pid, SIGINT);
    }
}

/* Runs on a plain pthread that is not registered with the D runtime: a
   thread blocked in a request to its own FUSE mount cannot take the GC's
   stop-the-world signal, so it must not be a D thread. */
private extern(C) void* kickMount(void* arg) nothrow
{
    stat_t st;
    stat(cast(const(char)*) arg, &st);
    return null;
}

/**
 * Mounts an Operations object and runs the multi-threaded libfuse loop on a
 * background thread. Unlike fuse_main() this installs no signal handlers, so
 * the host process keeps its own, and it does not daemonise.
 */
export class BackgroundFuse
{
private:
    fuse* f;
    Operations ops;          // referenced from C via private_data, keep alive
    fuse_operations fops;
    Thread loopThread;
    string mountpoint;
    int loopResult;

    void runLoop()
    {
        loopResult = fuse_loop_mt_31(f, 0);
    }

public:
    /**
     * Mounts ops on mountpoint and starts the loop. Throws on failure, in
     * which case nothing is left mounted.
     *
     * Params:
     *   fsname     = argv[0] for libfuse and the source shown in /proc/mounts
     *   mountopts  = options passed as -o (e.g. "default_permissions")
     */
    void start(Operations ops, string fsname, string mountpoint,
        string[] mountopts)
    {
        import std.exception : enforce;
        enforce(f is null, "already mounted");

        string[] args = [fsname];
        if (mountopts.length > 0)
            args ~= format("-o%s", mountopts.join(","));
        auto cargs = array(map!(a => cast(char*) toStringz(a))(args)) ~ null;
        fuse_args fargs = fuse_args(cast(int) args.length, cargs.ptr, 0);

        this.ops = ops;
        this.mountpoint = mountpoint;
        fops = makeOperations();
        f = fuse_new_31(&fargs, &fops, fuse_operations.sizeof, &this.ops);
        enforce(f !is null, "fuse_new failed for " ~ mountpoint);
        if (fuse_mount(f, toStringz(mountpoint)) != 0)
        {
            fuse_destroy(f);
            f = null;
            throw new Exception("fuse_mount failed for " ~ mountpoint);
        }

        loopThread = new Thread(&runLoop);
        loopThread.start();
    }

    bool mounted()
    {
        return f !is null;
    }

    /**
     * Stops the loop, unmounts and frees the handle. Requests already being
     * handled finish first, so anything they block on (e.g. a download)
     * should be cancelled before calling this. Idempotent.
     *
     * Returns: false if the loop did not stop within the timeout; the mount
     * is then detached lazily and the handle leaked.
     */
    bool stop(uint timeoutSeconds = 10)
    {
        if (f is null)
            return true;

        /* fuse_exit only sets a flag that the workers check after a
           request. Send uncached requests (a lookup of a name that does
           not exist) until one of them notices and the loop returns. */
        fuse_exit(f);
        /* C heap and never freed: a kicker may outlive this call */
        import core.sys.posix.string : strdup;
        auto probe = strdup(toStringz(mountpoint ~ "/.onedrive-fuse-stop"));
        auto deadline = MonoTime.currTime + dur!"seconds"(timeoutSeconds);
        while (loopThread.isRunning && MonoTime.currTime < deadline)
        {
            pthread_t kicker;
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            pthread_create(&kicker, &attr, &kickMount, cast(void*) probe);
            pthread_attr_destroy(&attr);
            foreach (i; 0 .. 10)
            {
                if (!loopThread.isRunning)
                    break;
                Thread.sleep(dur!"msecs"(20));
            }
        }

        bool clean = !loopThread.isRunning;
        if (clean)
        {
            loopThread.join(false);
            fuse_unmount(f);
            fuse_destroy(f);
        }
        else
        {
            /* Workers are still inside a handler. Detach the mount so no new
               requests arrive; the loop ends when they return. */
            fuse_unmount(f);
        }
        f = null;
        return clean;
    }

    /// fuse_loop_mt() result once stopped: 0 on a clean exit
    int result()
    {
        return loopResult;
    }
}
