/* D counterpart of abiprobe.c: prints the same sizes and offsets from the
 * D bindings so both outputs can be diffed. */
import core.stdc.stdio : printf;
import core.sys.posix.sys.stat : stat_t;
import core.sys.posix.sys.statvfs : statvfs_t;
import core.sys.posix.fcntl : flock;
import core.sys.posix.time : timespec;
import c.fuse.fuse;

/* C field names that are D keywords or clash in the bindings */
string cname(string f)
{
	if (f == "_fuse") return "fuse";
	if (f == "debug_") return "debug";
	return f;
}

void dump(T)(string name)
{
	printf("sizeof %.*s %zu\n", cast(int) name.length, name.ptr, T.sizeof);
	static foreach (f; __traits(allMembers, T))
	{
		static if (is(typeof(__traits(getMember, T, f).offsetof)) && f[0] != '_' || f == "_fuse")
		{{
			auto n = cname(f);
			printf("offsetof %.*s.%.*s %zu\n", cast(int) name.length, name.ptr,
				cast(int) n.length, n.ptr, __traits(getMember, T, f).offsetof);
		}}
	}
}

void bit(string f)()
{
	fuse_file_info fi;
	mixin("fi." ~ f ~ " = 1;");
	uint w = *cast(uint*)((cast(ubyte*) &fi) + int.sizeof);
	printf("bit fuse_file_info.%.*s 0x%x\n", cast(int) f.length, f.ptr, w);
}

void main()
{
	dump!fuse_file_info("fuse_file_info");
	static foreach (f; ["writepage", "direct_io", "keep_cache", "flush", "nonseekable", "flock_release", "cache_readdir", "noflush"])
		bit!f();
	dump!fuse_conn_info("fuse_conn_info");
	dump!fuse_config("fuse_config");
	dump!fuse_context("fuse_context");
	dump!fuse_operations("fuse_operations");
	dump!fuse_args("fuse_args");
	printf("sizeof stat %zu\nsizeof statvfs %zu\nsizeof flock %zu\nsizeof timespec %zu\n",
		stat_t.sizeof, statvfs_t.sizeof, flock.sizeof, timespec.sizeof);
}
