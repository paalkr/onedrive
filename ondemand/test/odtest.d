/*
 * Standalone test harness for src/ondemand.d against the stub hydration
 * module. Builds a temp ItemDatabase (the real src/itemdb.d), a fake remote
 * and a backing dir under <work>, mounts OnDemandFs on <mnt>, prints every
 * change event, and stops when <work>/stop appears. Driven by run-test.sh.
 *
 * Usage: odtest <work> <mnt> [downloadDelayMsecs]
 */
import core.time : dur;
import std.concurrency : receiveTimeout, thisTid;
import std.conv : to;
import std.datetime : SysTime, DateTime, UTC;
import std.file;
import std.path : buildPath;
import std.stdio;

import hydration;
import itemdb;
import log;
import ondemand;

enum driveId = "drive1";

void main(string[] args)
{
	string work = args[1];
	string mnt = args[2];
	uint delay = args.length > 3 ? args[3].to!uint : 0;

	initialiseLogging(false, false);
	scope(exit) shutdownLogging();

	string remote = buildPath(work, "remote");
	string backing = buildPath(work, "backing");
	mkdirRecurse(buildPath(remote, "docs/sub"));
	mkdirRecurse(buildPath(backing, "docs/sub"));
	mkdirRecurse(buildPath(backing, "emptydir"));

	auto db = new ItemDatabase(buildPath(work, "items.sqlite3"));
	auto svc = new HydrationService(null, db, backing);
	HydrationService.fakeRemoteDir = remote;
	HydrationService.downloadDelayMsecs = delay;

	auto mtime = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
	void add(string id, string parent, string name, ItemType type, string size = null)
	{
		Item item = { driveId: driveId, id: id, name: name, type: type, mtime: mtime,
			parentId: parent, size: size, eTag: "e" ~ id };
		db.insert(item);
	}
	void onlineFile(string id, string parent, string rel, string content)
	{
		std.file.write(buildPath(remote, rel), content);
		import std.path : baseName;
		add(id, parent, baseName(rel), ItemType.file, content.length.to!string);
		svc.setStateForTest(driveId, id, rel, HydrationState.onlineOnly);
	}

	add("root", null, "root", ItemType.root);
	add("d-docs", "root", "docs", ItemType.dir);
	add("d-sub", "d-docs", "sub", ItemType.dir);
	add("d-empty", "root", "emptydir", ItemType.dir);
	string big;
	foreach (i; 0 .. 20000) big ~= "line " ~ i.to!string ~ "\n";
	onlineFile("f-big", "d-docs", "docs/big.txt", big);
	onlineFile("f-trunc", "d-docs", "docs/trunc.txt", "old content that must not be downloaded\n");
	onlineFile("f-move", "d-docs", "docs/move-me.txt", "move me\n");
	onlineFile("f-del", "d-docs", "docs/delete-me.txt", "delete me\n");
	onlineFile("f-pin", "d-docs", "docs/pin-me.txt", "pin me\n");
	onlineFile("f-deep", "d-sub", "docs/sub/deep.txt", "deep\n");
	onlineFile("f-write", "root", "write-me.txt", "0123456789\n");
	// Hydrated file: present in the backing dir
	std.file.write(buildPath(backing, "local.txt"), "hydrated content\n");
	add("f-local", "root", "local.txt", ItemType.file, "17");
	setTimes(buildPath(backing, "local.txt"), mtime, mtime);
	svc.setStateForTest(driveId, "f-local", "local.txt", HydrationState.hydrated);

	auto queue = new OnDemandChangeQueue();
	startOnDemandMount(db, svc, queue, thisTid, mnt, backing, driveId, "root");
	writeln("READY");
	stdout.flush();

	string stopFile = buildPath(work, "stop");
	while (!exists(stopFile)) {
		receiveTimeout(dur!"msecs"(100), (OnDemandWake w) {
			foreach (c; queue.drain()) {
				if (c.oldPath is null) writeln("EVENT ", c.kind, " ", c.path);
				else writeln("EVENT ", c.kind, " ", c.oldPath, " -> ", c.path);
			}
			stdout.flush();
		});
	}
	foreach (id; ["f-big", "f-trunc", "f-move", "f-pin", "f-write"])
		writeln("DOWNLOADS ", id, " ", svc.downloadCount(driveId, id));
	svc.shutdown();
	stopOnDemandMount();
	writeln("STOPPED");
	stdout.flush();
	db.closeDatabaseFile();
}
