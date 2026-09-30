// What is this module called?
module ondemandcli;

// What does this module require to function?
import core.stdc.errno;
import core.stdc.string : strerror;
import core.sys.linux.sys.xattr : getxattr, setxattr;
import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.stdio;
import std.string;

// What other modules that we have created do we need to import?
import config;

// Files On-Demand CLI: --download/--pin/--unpin/--free/--status <path>.
// Works purely through extended attributes on the path inside a running on-demand mount, so it
// needs no database access or authentication and works while the monitor process is running.

private enum stateXattr = "user.onedrive.state";
private enum actionXattr = "user.onedrive.action";
// Filesystem type of the on-demand FUSE mount as listed in /proc/self/mounts
private enum onDemandMountType = "fuse.onedrive";

// Which on-demand CLI command, if any, was requested. The option values are stored in these keys.
private immutable string[] onDemandCommandKeys = ["on_demand_cli_download", "on_demand_cli_pin", "on_demand_cli_unpin", "on_demand_cli_free", "on_demand_cli_status"];

bool onDemandCommandRequested(ApplicationConfig appConfig) {
	foreach (key; onDemandCommandKeys) {
		if (!appConfig.getValueString(key).empty) return true;
	}
	return false;
}

// Run the requested on-demand CLI command. Returns the process exit code.
int runOnDemandCommand(ApplicationConfig appConfig) {
	string commandKey;
	foreach (key; onDemandCommandKeys) {
		if (!appConfig.getValueString(key).empty) {
			if (!commandKey.empty) {
				stderr.writeln("ERROR: Only one of --download, --pin, --unpin, --free or --status can be used at a time");
				return 1;
			}
			commandKey = key;
		}
	}

	string path = buildNormalizedPath(absolutePath(expandTilde(appConfig.getValueString(commandKey))));

	string mountPoint = findOnDemandMount(path);
	if (mountPoint.empty) {
		string configuredMountPoint = buildNormalizedPath(absolutePath(expandTilde(appConfig.getValueString("sync_dir"))));
		if ((path == configuredMountPoint) || startsWith(path, configuredMountPoint ~ "/")) {
			stderr.writeln("ERROR: The on-demand mount is not active at " ~ configuredMountPoint ~ " (is the client running with --monitor --on-demand?)");
		} else {
			stderr.writeln("ERROR: Not inside an on-demand mount: " ~ path);
		}
		return 1;
	}

	if (commandKey == "on_demand_cli_status") {
		string state;
		int error = readXattr(path, stateXattr, state);
		if (error != 0) return reportXattrError(path, mountPoint, error);
		writeln(state ~ "\t" ~ path);
		return 0;
	}

	string action = commandKey["on_demand_cli_".length .. $];
	int error = writeXattr(path, actionXattr, action);
	if (error != 0) return reportXattrError(path, mountPoint, error);
	writeln(action ~ ": accepted\t" ~ path);
	return 0;
}

// Longest mountpoint of an active on-demand FUSE mount that contains 'path', or null
string findOnDemandMount(string path) {
	string best;
	string mounts;
	try {
		mounts = readText("/proc/self/mounts");
	} catch (Exception e) {
		return null;
	}
	foreach (line; mounts.splitLines()) {
		auto fields = line.split(" ");
		if (fields.length < 3) continue;
		if (fields[2] != onDemandMountType) continue;
		string mountPoint = unescapeMountField(fields[1]);
		if ((path == mountPoint) || startsWith(path, mountPoint == "/" ? "/" : mountPoint ~ "/")) {
			if (mountPoint.length > best.length) best = mountPoint;
		}
	}
	return best;
}

// /proc/mounts escapes space, tab, newline and backslash as \ooo octal
string unescapeMountField(string field) {
	auto result = appender!string();
	for (size_t i = 0; i < field.length; i++) {
		if ((field[i] == '\\') && (i + 3 < field.length) && isOctal(field[i + 1 .. i + 4])) {
			result.put(cast(char) to!int(field[i + 1 .. i + 4], 8));
			i += 3;
		} else {
			result.put(field[i]);
		}
	}
	return result.data;
}

private bool isOctal(string s) {
	if (s.length != 3) return false;
	foreach (c; s) {
		if ((c < '0') || (c > '7')) return false;
	}
	return true;
}

private int readXattr(string path, string name, out string value) {
	ubyte[256] buffer;
	auto size = getxattr(toStringz(path), toStringz(name), buffer.ptr, buffer.length);
	if (size < 0) return errno;
	value = cast(string) buffer[0 .. size].idup;
	return 0;
}

private int writeXattr(string path, string name, string value) {
	int result = setxattr(toStringz(path), toStringz(name), value.ptr, value.length, 0);
	if (result != 0) return errno;
	return 0;
}

private int reportXattrError(string path, string mountPoint, int error) {
	switch (error) {
		case ENOTCONN:
			stderr.writeln("ERROR: The on-demand mount is not active (the client is not running). Unmount it with: fusermount3 -u -z " ~ mountPoint);
			break;
		case ENOENT:
			stderr.writeln("ERROR: No such file or directory in the on-demand mount: " ~ path);
			break;
		case EBUSY:
			stderr.writeln("ERROR: Refused: the file is pinned or has local changes that are not uploaded yet: " ~ path);
			break;
		case ENODATA:
		case ENOTSUP:
			stderr.writeln("ERROR: The on-demand mount does not support this operation on: " ~ path);
			break;
		case ENETUNREACH:
			stderr.writeln("ERROR: Microsoft OneDrive is not reachable: " ~ path);
			break;
		default:
			stderr.writeln("ERROR: " ~ path ~ ": " ~ to!string(fromStringz(strerror(error))));
			break;
	}
	return 1;
}
