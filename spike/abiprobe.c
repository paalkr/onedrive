/* Prints sizes and offsets of the libfuse3 high-level API structs so that
 * the D bindings in src/c/fuse/ can be diffed against the installed headers.
 * Build: cc $(pkg-config --cflags fuse3) -o abiprobe abiprobe.c */
#define FUSE_USE_VERSION 31
#include <fuse.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define S(t) printf("sizeof %s %zu\n", #t, sizeof(struct t))
#define O(t, f) printf("offsetof %s.%s %zu\n", #t, #f, offsetof(struct t, f))

static unsigned int bitword(struct fuse_file_info *fi)
{
	unsigned int w;
	memcpy(&w, (char *)fi + offsetof(struct fuse_file_info, flags) + sizeof(int), sizeof(w));
	return w;
}

#define B(f) do { struct fuse_file_info fi; memset(&fi, 0, sizeof(fi)); fi.f = 1; \
	printf("bit fuse_file_info.%s 0x%x\n", #f, bitword(&fi)); } while (0)

int main(void)
{
	S(fuse_file_info);
	O(fuse_file_info, flags); O(fuse_file_info, fh); O(fuse_file_info, lock_owner); O(fuse_file_info, poll_events);
	B(writepage); B(direct_io); B(keep_cache); B(flush); B(nonseekable); B(flock_release); B(cache_readdir); B(noflush);

	S(fuse_conn_info);
	O(fuse_conn_info, proto_major); O(fuse_conn_info, proto_minor); O(fuse_conn_info, max_write);
	O(fuse_conn_info, max_read); O(fuse_conn_info, max_readahead); O(fuse_conn_info, capable);
	O(fuse_conn_info, want); O(fuse_conn_info, max_background); O(fuse_conn_info, congestion_threshold);
	O(fuse_conn_info, time_gran); O(fuse_conn_info, reserved);

	S(fuse_config);
	O(fuse_config, set_gid); O(fuse_config, gid); O(fuse_config, set_uid); O(fuse_config, uid);
	O(fuse_config, set_mode); O(fuse_config, umask); O(fuse_config, entry_timeout);
	O(fuse_config, negative_timeout); O(fuse_config, attr_timeout); O(fuse_config, intr);
	O(fuse_config, intr_signal); O(fuse_config, remember); O(fuse_config, hard_remove);
	O(fuse_config, use_ino); O(fuse_config, readdir_ino); O(fuse_config, direct_io);
	O(fuse_config, kernel_cache); O(fuse_config, auto_cache); O(fuse_config, no_rofd_flush);
	O(fuse_config, ac_attr_timeout_set); O(fuse_config, ac_attr_timeout); O(fuse_config, nullpath_ok);
	O(fuse_config, show_help); O(fuse_config, modules); O(fuse_config, debug);

	S(fuse_context);
	O(fuse_context, fuse); O(fuse_context, uid); O(fuse_context, gid); O(fuse_context, pid);
	O(fuse_context, private_data); O(fuse_context, umask);

	S(fuse_operations);
	O(fuse_operations, getattr); O(fuse_operations, readlink); O(fuse_operations, mknod);
	O(fuse_operations, mkdir); O(fuse_operations, unlink); O(fuse_operations, rmdir);
	O(fuse_operations, symlink); O(fuse_operations, rename); O(fuse_operations, link);
	O(fuse_operations, chmod); O(fuse_operations, chown); O(fuse_operations, truncate);
	O(fuse_operations, open); O(fuse_operations, read); O(fuse_operations, write);
	O(fuse_operations, statfs); O(fuse_operations, flush); O(fuse_operations, release);
	O(fuse_operations, fsync); O(fuse_operations, setxattr); O(fuse_operations, getxattr);
	O(fuse_operations, listxattr); O(fuse_operations, removexattr); O(fuse_operations, opendir);
	O(fuse_operations, readdir); O(fuse_operations, releasedir); O(fuse_operations, fsyncdir);
	O(fuse_operations, init); O(fuse_operations, destroy); O(fuse_operations, access);
	O(fuse_operations, create); O(fuse_operations, lock); O(fuse_operations, utimens);
	O(fuse_operations, bmap); O(fuse_operations, ioctl); O(fuse_operations, poll);
	O(fuse_operations, write_buf); O(fuse_operations, read_buf); O(fuse_operations, flock);
	O(fuse_operations, fallocate); O(fuse_operations, copy_file_range); O(fuse_operations, lseek);

	printf("sizeof stat %zu\nsizeof statvfs %zu\nsizeof flock %zu\nsizeof timespec %zu\n",
		sizeof(struct stat), sizeof(struct statvfs), sizeof(struct flock), sizeof(struct timespec));
	return 0;
}
