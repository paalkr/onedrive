/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the Boost-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */
module c.fuse.common;

/*
 * Bindings for libfuse 3 <fuse3/fuse_common.h>, verified against libfuse
 * 3.14 with FUSE_USE_VERSION 31. Field order and sizes must match the C
 * ABI; see spike/abiprobe.c for the reference values.
 */

import std.bitmanip : bitfields;
import std.stdint;

extern (System) {
    /**
     * Connection information, passed to the ->init() method
     */
    struct fuse_conn_info
    {
        /** Major version of the protocol (read-only) */
        uint proto_major;

        /** Minor version of the protocol (read-only) */
        uint proto_minor;

        /** Maximum size of the write buffer */
        uint max_write;

        /** Maximum size of read requests */
        uint max_read;

        /** Maximum readahead */
        uint max_readahead;

        /** Capability flags that the kernel supports (read-only) */
        uint capable;

        /** Capability flags that the filesystem wants to enable */
        uint want;

        /** Maximum number of pending "background" requests */
        uint max_background;

        /** Kernel congestion threshold parameter */
        uint congestion_threshold;

        /** Timestamp granularity supported by the file-system */
        uint time_gran;

        /** For future use. */
        uint[22] reserved;
    }

    /**
     * Information about an open file
     */
    struct fuse_file_info
    {
        /** Open flags. Available in open() and release() */
        int flags;

        /* C bitfields, allocated LSB first in one unsigned int */
        mixin(bitfields!(
            /** Write caused by a delayed write from the page cache */
            uint, "writepage", 1,
            /** Can be filled in by open, to use direct I/O on this file */
            uint, "direct_io", 1,
            /** Can be filled in by open, cached data need not be invalidated */
            uint, "keep_cache", 1,
            /** Indicates a flush operation */
            uint, "flush", 1,
            /** Can be filled in by open, the file is not seekable */
            uint, "nonseekable", 1,
            /** flock locks for this file should be released */
            uint, "flock_release", 1,
            /** Can be filled in by opendir, enable readdir caching */
            uint, "cache_readdir", 1,
            /** Can be filled in by open, flush is not needed on close */
            uint, "noflush", 1,
            /** Padding. Reserved for future use */
            uint, "padding", 24));

        /** Padding. Reserved for future use */
        uint padding2;

        /** File handle id. May be filled in by filesystem in create,
          open, and opendir() */
        uint64_t fh;

        /** Lock owner id. Available in locking operations and flush */
        uint64_t lock_owner;

        /** Requested poll events. Available in ->poll */
        uint32_t poll_events;
    }

    /* Layout checks for LP64 Linux (x86_64, aarch64), values from spike/abiprobe.c */
    static if (size_t.sizeof == 8)
    {
        static assert(fuse_conn_info.sizeof == 128);
        static assert(fuse_conn_info.time_gran.offsetof == 36);
        static assert(fuse_conn_info.reserved.offsetof == 40);

        static assert(fuse_file_info.sizeof == 40);
        static assert(fuse_file_info.padding2.offsetof == 8);
        static assert(fuse_file_info.fh.offsetof == 16);
        static assert(fuse_file_info.lock_owner.offsetof == 24);
        static assert(fuse_file_info.poll_events.offsetof == 32);
    }
}
