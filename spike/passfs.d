/*
 * Spike: read-only passthrough filesystem that logs every open() with the
 * caller pid, comm, exe, parent comm and NSpid. Used to see which processes
 * a file manager makes read file content (thumbnailing). Not part of the
 * onedrive build.
 *
 * Build:   ldc2 -I../src -of=passfs passfs.d ../src/c/fuse/common.d \
 *              ../src/c/fuse/fuse.d ../src/fused/fuse.d -L-lfuse3
 * Run:     ./passfs <backingdir> <mountpoint>
 */
import std.algorithm : filter, map, startsWith;
import std.array : array;
import std.conv : to;
import std.file : readText, dirEntries, SpanMode, readLink, DirEntry, exists;
import std.path : baseName;
import std.stdio : stderr, File;
import std.string : strip, splitLines;
import errno = core.stdc.errno;
import core.sys.posix.sys.stat;

import c.fuse.fuse : fuse_get_context;
import fused.fuse;

string procField(int pid, string name)
{
	try
		return readText("/proc/" ~ pid.to!string ~ "/" ~ name).strip;
	catch (Exception e)
		return "?";
}

string statusField(int pid, string key)
{
	foreach (line; procField(pid, "status").splitLines)
		if (line.startsWith(key ~ ":"))
			return line[key.length + 1 .. $].strip;
	return "?";
}

string exeOf(int pid)
{
	try
		return readLink("/proc/" ~ pid.to!string ~ "/exe");
	catch (Exception e)
		return "?";
}

class PassFs : Operations
{
	private immutable string backing;

	this(string backing)
	{
		this.backing = backing;
	}

	private string backed(const(char)[] path)
	{
		return backing ~ path.idup;
	}

	override void getattr(const(char)[] path, ref stat_t st)
	{
		import std.string : toStringz;
		if (lstat(backed(path).toStringz, &st) != 0)
			throw new FuseException(errno.ENOENT);
		// present everything read-only
		st.st_mode &= ~(S_IWUSR | S_IWGRP | S_IWOTH);
	}

	override string[] readdir(const(char)[] path)
	{
		if (!exists(backed(path)))
			throw new FuseException(errno.ENOENT);
		return [".", ".."] ~ dirEntries(backed(path), SpanMode.shallow, false)
			.map!(e => baseName(e.name)).array;
	}

	override bool access(const(char)[] path, int mode)
	{
		return exists(backed(path));
	}

	override void open(const(char)[] path)
	{
		auto ctx = fuse_get_context();
		int pid = ctx.pid;
		int ppid = statusField(pid, "PPid").to!int;
		stderr.writefln("passfs: open(%s) pid=%d nspid=[%s] comm=%s exe=%s parent=%s(%s)",
			path, pid, statusField(pid, "NSpid"), procField(pid, "comm"), exeOf(pid),
			procField(ppid, "comm"), exeOf(ppid));
		stderr.flush();
		if (!exists(backed(path)))
			throw new FuseException(errno.ENOENT);
	}

	override void release(const(char)[] path)
	{
	}

	override ulong read(const(char)[] path, ubyte[] buf, ulong offset)
	{
		auto f = File(backed(path), "rb");
		f.seek(offset);
		auto n = f.rawRead(buf).length;
		auto ctx = fuse_get_context();
		stderr.writefln("passfs: read(%s) off=%d len=%d got=%d comm=%s", path, offset, buf.length, n, procField(ctx.pid, "comm"));
		stderr.flush();
		return n;
	}

	override void exception(Exception e)
	{
		stderr.writefln("passfs: exception: %s", e.msg);
	}
}

int main(string[] args)
{
	if (args.length < 3)
	{
		stderr.writefln("usage: %s <backingdir> <mountpoint>", args[0]);
		return 1;
	}
	auto f = new Fuse("passfs", true, true);
	f.mount(new PassFs(args[1]), args[2], ["ro", "fsname=passfs"]);
	stderr.writefln("passfs: fuse_main returned");
	return 0;
}
