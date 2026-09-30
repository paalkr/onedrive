#!/usr/bin/env python3
"""Prints inotify events for one directory, one line each, flushed:
   <mask names> <name>. Usage: inotify-watch.py <dir>"""
import ctypes, os, struct, sys

NAMES = {0x1: "IN_ACCESS", 0x2: "IN_MODIFY", 0x4: "IN_ATTRIB", 0x8: "IN_CLOSE_WRITE",
         0x10: "IN_CLOSE_NOWRITE", 0x20: "IN_OPEN", 0x40: "IN_MOVED_FROM", 0x80: "IN_MOVED_TO",
         0x100: "IN_CREATE", 0x200: "IN_DELETE", 0x400: "IN_DELETE_SELF", 0x800: "IN_MOVE_SELF",
         0x2000: "IN_UNMOUNT", 0x4000: "IN_Q_OVERFLOW", 0x8000: "IN_IGNORED", 0x40000000: "IN_ISDIR"}
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init()
if libc.inotify_add_watch(fd, sys.argv[1].encode(), 0xfff) < 0:
    sys.exit("inotify_add_watch: " + os.strerror(ctypes.get_errno()))
print("WATCHING", flush=True)
while True:
    buf = os.read(fd, 65536)
    i = 0
    while i < len(buf):
        wd, mask, cookie, length = struct.unpack_from("iIII", buf, i)
        name = buf[i + 16:i + 16 + length].rstrip(b"\0").decode(errors="replace")
        i += 16 + length
        print("|".join(n for b, n in NAMES.items() if mask & b), name, flush=True)
        if mask & 0x8000:
            sys.exit(0)
