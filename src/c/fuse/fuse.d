/*
 * From: https://code.google.com/p/dutils/
 *
 * Licensed under the Apache License 2.0. See
 * http://www.apache.org/licenses/LICENSE-2.0
 */
module c.fuse.fuse;
public import c.fuse.common;

/*
 * Bindings for the libfuse 3 high-level API <fuse3/fuse.h>, verified against
 * libfuse 3.14 with FUSE_USE_VERSION 31. Field order and sizes must match the
 * C ABI; see spike/abiprobe.c for the reference values.
 */

import std.stdint;
import core.sys.posix.sys.stat;
import core.sys.posix.sys.statvfs;
import core.sys.posix.sys.types;
import core.sys.posix.fcntl;
import core.sys.posix.time;

extern (System)
{
    struct fuse;
    struct fuse_session;

    /** Argument list, <fuse3/fuse_opt.h> */
    struct fuse_args
    {
        int argc;
        char** argv;
        int allocated;
    }

    struct fuse_pollhandle;
    struct fuse_bufvec;

    alias flock _flock;

    /** Readdir flags, passed to ->readdir() */
    enum fuse_readdir_flags : int
    {
        FUSE_READDIR_PLUS = (1 << 0)
    }

    /** Readdir flags, passed to fuse_fill_dir_t callback */
    enum fuse_fill_dir_flags : int
    {
        FUSE_FILL_DIR_PLUS = (1 << 1)
    }

    alias fuse_fill_dir_t =
        int function(void* buf, const(char)* name, const(stat_t)* stbuf,
            off_t off, fuse_fill_dir_flags flags);

    /**
     * Configuration of the high-level API, passed to ->init()
     */
    struct fuse_config
    {
        int set_gid;
        uint gid;
        int set_uid;
        uint uid;
        int set_mode;
        uint umask;
        double entry_timeout;
        double negative_timeout;
        double attr_timeout;
        int intr;
        int intr_signal;
        int remember;
        int hard_remove;
        int use_ino;
        int readdir_ino;
        int direct_io;
        int kernel_cache;
        int auto_cache;
        int no_rofd_flush;
        int ac_attr_timeout_set;
        double ac_attr_timeout;
        int nullpath_ok;

        /* The following options are not accessible from the command line
           and are for libfuse internal use */
        int show_help;
        char* modules;
        int debug_;
    }

    struct fuse_operations
    {
        int function(const(char)*, stat_t*, fuse_file_info*) getattr;
        int function(const(char)*, char*, size_t) readlink;
        int function(const(char)*, mode_t, dev_t) mknod;
        int function(const(char)*, mode_t) mkdir;
        int function(const(char)*) unlink;
        int function(const(char)*) rmdir;
        int function(const(char)*, const(char)*) symlink;
        int function(const(char)*, const(char)*, uint flags) rename;
        int function(const(char)*, const(char)*) link;
        int function(const(char)*, mode_t, fuse_file_info*) chmod;
        int function(const(char)*, uid_t, gid_t, fuse_file_info*) chown;
        int function(const(char)*, off_t, fuse_file_info*) truncate;
        int function(const(char)*, fuse_file_info*) open;
        int function(const(char)*, char*, size_t, off_t, fuse_file_info*) read;
        int function(const(char)*, const(char)*, size_t, off_t,
                fuse_file_info*) write;
        int function(const(char)*, statvfs_t*) statfs;
        int function(const(char)*, fuse_file_info*) flush;
        int function(const(char)*, fuse_file_info*) release;
        int function(const(char)*, int, fuse_file_info*) fsync;
        int function(const(char)*, const(char)*, const(char)*, size_t, int)
            setxattr;
        int function(const(char)*, const(char)*, char*, size_t) getxattr;
        int function(const(char)*, char*, size_t) listxattr;
        int function(const(char)*, const(char)*) removexattr;
        int function(const(char)*, fuse_file_info*) opendir;
        int function(const(char)*, void*, fuse_fill_dir_t, off_t,
                fuse_file_info*, fuse_readdir_flags) readdir;
        int function(const(char)*, fuse_file_info*) releasedir;
        int function(const(char)*, int, fuse_file_info*) fsyncdir;
        void* function(fuse_conn_info* conn, fuse_config* cfg) init;
        void function(void* private_data) destroy;
        int function(const(char)*, int) access;
        int function(const(char)*, mode_t, fuse_file_info*) create;
        int function(const(char)*, fuse_file_info*, int cmd, _flock*) lock;
        int function(const(char)*, const(timespec)*, fuse_file_info*) utimens;
        int function(const(char)*, size_t blocksize, uint64_t* idx) bmap;
        /* FUSE_USE_VERSION < 35: cmd is int */
        int function(const(char)*, int cmd, void* arg, fuse_file_info*,
                uint flags, void* data) ioctl;
        int function(const(char)*, fuse_file_info*, fuse_pollhandle* ph,
                uint* reventsp) poll;
        int function(const(char)*, fuse_bufvec* buf, off_t off,
                fuse_file_info*) write_buf;
        int function(const(char)*, fuse_bufvec** bufp, size_t size, off_t off,
                fuse_file_info*) read_buf;
        int function(const(char)*, fuse_file_info*, int op) flock;
        int function(const(char)*, int, off_t, off_t, fuse_file_info*)
            fallocate;
        ssize_t function(const(char)* path_in, fuse_file_info* fi_in,
                off_t offset_in, const(char)* path_out, fuse_file_info* fi_out,
                off_t offset_out, size_t size, int flags) copy_file_range;
        off_t function(const(char)*, off_t off, int whence, fuse_file_info*)
            lseek;
    }

    struct fuse_context
    {
        /** Pointer to the fuse object */
        fuse* _fuse;

        uid_t uid; // User ID of the calling process
        gid_t gid; // Group ID of the calling process
        pid_t pid; // Process ID of the calling thread

        void* private_data; // Private filesystem data

        mode_t umask; // Umask of the calling process
    }

    /* Layout checks for LP64 Linux (x86_64, aarch64), values from spike/abiprobe.c */
    static if (size_t.sizeof == 8)
    {
        static assert(fuse_config.sizeof == 128);
        static assert(fuse_config.entry_timeout.offsetof == 24);
        static assert(fuse_config.ac_attr_timeout.offsetof == 96);
        static assert(fuse_config.modules.offsetof == 112);
        static assert(fuse_config.debug_.offsetof == 120);

        static assert(fuse_operations.sizeof == 336);
        static assert(fuse_operations.init.offsetof == 216);
        static assert(fuse_operations.utimens.offsetof == 256);
        static assert(fuse_operations.lseek.offsetof == 328);

        static assert(fuse_context.sizeof == 40);
        static assert(fuse_context.pid.offsetof == 16);
        static assert(fuse_context.private_data.offsetof == 24);
        static assert(fuse_context.umask.offsetof == 32);

        static assert(fuse_args.sizeof == 24);
        static assert(fuse_args.argv.offsetof == 8);
        static assert(fuse_args.allocated.offsetof == 16);
    }

    fuse_context* fuse_get_context();
    void fuse_exit(fuse* f);
    int fuse_version();

    /* Exported as fuse_new_31@@FUSE_3.1 by libfuse 3.14. fuse_new() copies
       *op but keeps private_data as given. Mount options in args (-o ...)
       are parsed here, not by fuse_mount(). */
    fuse* fuse_new_31(fuse_args* args, const(fuse_operations)* op,
        size_t op_size, void* private_data);
    int fuse_mount(fuse* f, const(char)* mountpoint);
    void fuse_unmount(fuse* f);
    void fuse_destroy(fuse* f);
    fuse_session* fuse_get_session(fuse* f);
    int fuse_session_exited(fuse_session* se);

    /* FUSE_USE_VERSION < 32 variant, exported as fuse_loop_mt_31@@FUSE_3.2.
       Takes clone_fd instead of struct fuse_loop_config, so no config
       struct has to be mirrored. Unlike fuse_main() it installs no signal
       handlers. Returns 0 on a clean exit. */
    int fuse_loop_mt_31(fuse* f, int clone_fd);

    /* libfuse >= 3.12: the loop configuration is opaque and set through
       these functions (all @FUSE_3.12). fuse_loop_mt_31 runs with the
       default of at most 10 worker threads, so ten slow requests (e.g.
       downloads) block every other request. */
    struct fuse_loop_config;
    fuse_loop_config* fuse_loop_cfg_create();
    void fuse_loop_cfg_destroy(fuse_loop_config* config);
    void fuse_loop_cfg_set_idle_threads(fuse_loop_config* config, uint value);
    void fuse_loop_cfg_set_max_threads(fuse_loop_config* config, uint value);
    void fuse_loop_cfg_set_clone_fd(fuse_loop_config* config, uint value);
    int fuse_loop_mt_312(fuse* f, fuse_loop_config* config);

    /* Cache invalidation notifications, <fuse3/fuse_lowlevel.h>. Inode
       numbers are the high-level library's node ids, which it reports as
       st_ino when use_ino is off (1 is the root). None of these may be
       called from a request handler of a related operation. */
    alias fuse_ino_t = uint64_t;
    nothrow int fuse_lowlevel_notify_inval_inode(fuse_session* se, fuse_ino_t ino,
        off_t off, off_t len);
    nothrow int fuse_lowlevel_notify_inval_entry(fuse_session* se, fuse_ino_t parent,
        const(char)* name, size_t namelen);
    nothrow int fuse_lowlevel_notify_delete(fuse_session* se, fuse_ino_t parent,
        fuse_ino_t child, const(char)* name, size_t namelen);
    nothrow int fuse_invalidate_path(fuse* f, const(char)* path);

    /* Exported unversioned as fuse_main_real@@FUSE_3.0 by libfuse 3.14 */
    int fuse_main_real(int argc, char** argv, const(fuse_operations)* op,
        size_t op_size, void* private_data);
}


/* mapping of the fuse_main macro in fuse.h */
int fuse_main(int argc, char** argv, const(fuse_operations)* op, void* private_data)
{
    return fuse_main_real(argc, argv, op, fuse_operations.sizeof, private_data);
}
