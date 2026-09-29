/*
 * Spike: read-only hello filesystem on top of the fused wrapper and the
 * libfuse 3 bindings. Not part of the onedrive build.
 *
 * Layout:  /hello/  /hello/world.txt  (generated content)
 *
 * Build:   ldc2 -I../src -of=hellofs hellofs.d ../src/c/fuse/common.d \
 *              ../src/c/fuse/fuse.d ../src/fused/fuse.d -L-lfuse3
 * Run:     ./hellofs <mountpoint> [-s]
 */
import std.array : appender;
import std.conv : octal, to;
import std.file : readText;
import std.format : formattedWrite;
import std.stdio : stderr;
import std.process : environment;
import std.string : strip;
import core.memory : GC;
import errno = core.stdc.errno;
import core.sys.posix.sys.stat;
import core.sys.posix.unistd : getuid, getgid;

import c.fuse.fuse : fuse_get_context, fuse_version;
import fused.fuse;

class HelloFs : Operations
{
	private immutable string content;
	private immutable bool gcStress;

	this()
	{
		auto buf = appender!string();
		foreach (i; 1 .. 1001)
			buf.formattedWrite("hellofs generated line %d\n", i);
		content = buf.data;
		gcStress = environment.get("HELLOFS_GC") == "1";
	}

	override void getattr(const(char)[] path, ref stat_t st)
	{
		st = stat_t.init;
		st.st_uid = getuid();
		st.st_gid = getgid();
		switch (path)
		{
			case "/", "/hello":
				st.st_mode = S_IFDIR | octal!"555";
				st.st_nlink = 2;
				break;
			case "/hello/world.txt":
				st.st_mode = S_IFREG | octal!"444";
				st.st_nlink = 1;
				st.st_size = content.length;
				break;
			default:
				throw new FuseException(errno.ENOENT);
		}
	}

	override string[] readdir(const(char)[] path)
	{
		switch (path)
		{
			case "/": return [".", "..", "hello"];
			case "/hello": return [".", "..", "world.txt"];
			default: throw new FuseException(errno.ENOENT);
		}
	}

	override bool access(const(char)[] path, int mode)
	{
		return true;
	}

	override void open(const(char)[] path)
	{
		if (path != "/hello/world.txt")
			throw new FuseException(errno.ENOENT);
		auto ctx = fuse_get_context();
		string comm;
		try
			comm = readText("/proc/" ~ ctx.pid.to!string ~ "/comm").strip;
		catch (Exception e)
			comm = "<" ~ e.msg ~ ">";
		stderr.writefln("hellofs: open(%s) pid=%d uid=%d comm=%s", path, ctx.pid, ctx.uid, comm);
	}

	override void release(const(char)[] path)
	{
	}

	override ulong read(const(char)[] path, ubyte[] buf, ulong offset)
	{
		if (path != "/hello/world.txt")
			throw new FuseException(errno.ENOENT);
		if (offset >= content.length)
			return 0;
		auto n = content.length - offset;
		if (n > buf.length)
			n = buf.length;
		buf[0 .. n] = cast(const(ubyte)[]) content[offset .. offset + n];
		/* HELLOFS_GC=1: stop-the-world collection from a libfuse worker
		   thread on every read, to exercise GC suspend of attached threads */
		if (gcStress)
		{
			auto garbage = new ubyte[](4096);
			GC.collect();
		}
		return n;
	}

	override void exception(Exception e)
	{
		stderr.writefln("hellofs: exception: %s", e.msg);
	}
}


int main(string[] args)
{
	if (args.length < 2)
	{
		stderr.writefln("usage: %s <mountpoint> [-s]", args[0]);
		return 1;
	}
	bool threaded = !(args.length > 2 && args[2] == "-s");
	stderr.writefln("hellofs: libfuse version %d, threaded=%s", fuse_version(), threaded);
	auto f = new Fuse("hellofs", true, threaded);
	f.mount(new HelloFs(), args[1], ["ro", "fsname=hellofs"]);
	stderr.writefln("hellofs: fuse_main returned");
	return 0;
}
