/*
 * Standalone test harness for src/ondemand.d against the stub hydration
 * module. Builds a temp ItemDatabase (the real src/itemdb.d), a fake remote
 * and a backing dir under <work>, mounts OnDemandFs on <mnt>, prints every
 * change event, and stops when <work>/stop appears. Driven by run-test.sh.
 *
 * Moves under ./apply are applied to the database one second after their
 * event, as the engine would. For a move from a "*.tmp" file or under
 * ./etag the destination item gets a new eTag one second later instead,
 * as when the engine treats the move as a change of the destination and
 * uploads or re-downloads it. All other changes are never applied.
 *
 * Usage: odtest <work> <mnt> [downloadDelayMsecs]
 */
import core.time : dur;
import std.concurrency : receiveTimeout, thisTid;
import std.conv : to;
import std.datetime : SysTime, DateTime, UTC;
import std.file;
import std.path : baseName, buildPath, dirName;
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
	foreach (d; ["docs/sub", "docs/target", "apply/d1", "hold/d1", "shared"]) {
		mkdirRecurse(buildPath(remote, d));
		mkdirRecurse(buildPath(backing, d));
	}
	mkdirRecurse(buildPath(backing, "emptydir"));
	onDemandPendingMoveWaitSeconds = 2;
	onDemandPendingExpirySeconds = 15;
	HydrationService.webUrlDelayMsecs = 1500;

	auto db = new ItemDatabase(buildPath(work, "items.sqlite3"));
	auto svc = new HydrationService(null, db, backing);
	HydrationService.fakeRemoteDir = remote;
	HydrationService.downloadDelayMsecs = delay;

	auto mtime = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
	void add(string id, string parent, string name, ItemType type, string size = null,
		string drive = driveId)
	{
		Item item = { driveId: drive, id: id, name: name, type: type, mtime: mtime,
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
	onlineFile("f-trunc0", "d-docs", "docs/trunc0.txt", "old content for truncate -s 0\n");
	// V3: a directory whose only child is online-only, and files to rename over
	add("d-target", "d-docs", "target", ItemType.dir);
	onlineFile("f-target", "d-target", "docs/target/t.txt", "only child\n");
	onlineFile("f-victim", "d-docs", "docs/victim.txt", "victim\n");
	onlineFile("f-victim2", "d-docs", "docs/victim2.txt", "victim2 old\n");
	// V4: moves applied by the simulated engine (apply) and never applied (hold)
	add("d-apply", "root", "apply", ItemType.dir);
	add("d-apply1", "d-apply", "d1", ItemType.dir);
	onlineFile("f-apply", "d-apply1", "apply/d1/f.txt", "applied move\n");
	add("d-hold", "root", "hold", ItemType.dir);
	add("d-hold1", "d-hold", "d1", ItemType.dir);
	onlineFile("f-hold", "d-hold1", "hold/d1/g.txt", "held move\n");
	// Iteration 2: directory actions
	foreach (d; ["lib/sub"]) {
		mkdirRecurse(buildPath(remote, d));
		mkdirRecurse(buildPath(backing, d));
	}
	add("d-lib", "root", "lib", ItemType.dir);
	add("d-libsub", "d-lib", "sub", ItemType.dir);
	onlineFile("f-a", "d-lib", "lib/a.txt", "aaaa\n");
	onlineFile("f-b", "d-lib", "lib/b.txt", "bbbbbbbb\n");
	onlineFile("f-c", "d-libsub", "lib/sub/c.txt", "cccccccccccc\n");
	onlineFile("f-one", "root", "one.txt", "single file action\n");
	// Fix round 3: open handles and thumbnailers
	onlineFile("f-held", "root", "held.txt", "held open\n");
	onlineFile("f-thumb", "root", "thumb.jpg", "not really a jpeg\n");
	// Rename-over from a file that is not in the database (editor save)
	void localFile(string id, string parent, string rel, string content, HydrationState state)
	{
		std.file.write(buildPath(backing, rel), content);
		std.file.write(buildPath(remote, rel), content);
		add(id, parent, baseName(rel), ItemType.file, content.length.to!string);
		setTimes(buildPath(backing, rel), mtime, mtime);
		svc.setStateForTest(driveId, id, rel, state);
	}
	localFile("f-report", "root", "report.xlsx", "original report\n", HydrationState.hydrated);
	localFile("f-pinx", "root", "pinned.xlsx", "original pinned\n", HydrationState.pinned);
	add("d-etag", "root", "etag", ItemType.dir);
	mkdirRecurse(buildPath(backing, "etag"));
	mkdirRecurse(buildPath(remote, "etag"));
	localFile("f-src2", "d-etag", "etag/src2.txt", "source two\n", HydrationState.hydrated);
	localFile("f-dst2", "d-etag", "etag/dst2.txt", "destination two\n", HydrationState.pinned);
	localFile("f-src3", "root", "src3.txt", "source three\n", HydrationState.hydrated);
	localFile("f-dst3", "root", "dst3.txt", "destination three\n", HydrationState.pinned);
	// Iteration 3
	add("d-sync", "root", "syncdir", ItemType.dir);
	mkdirRecurse(buildPath(backing, "syncdir"));
	mkdirRecurse(buildPath(remote, "syncdir"));
	localFile("f-s1", "d-sync", "syncdir/s1.txt", "s1\n", HydrationState.hydrated);
	localFile("f-s2", "d-sync", "syncdir/s2.txt", "s2\n", HydrationState.hydrated);
	onlineFile("f-offline", "root", "offline.txt", "no url while offline\n");
	localFile("f-deferred", "root", "deferred.txt", "open while changed online\n", HydrationState.hydrated);
	// V-partial: a database item whose real name ends in .partial
	onlineFile("f-keep", "d-docs", "docs/keep.partial", "not an engine partial\n");
	// V2: a shared folder from another drive
	Item shortcut = { driveId: driveId, id: "r-shared", name: "shared", type: ItemType.remote,
		mtime: mtime, parentId: "root", remoteDriveId: "drive2", remoteId: "s-root" };
	db.insert(shortcut);
	add("s-root", null, "shared", ItemType.dir, null, "drive2");
	// Hydrated file: present in the backing dir
	std.file.write(buildPath(backing, "local.txt"), "hydrated content\n");
	add("f-local", "root", "local.txt", ItemType.file, "17");
	setTimes(buildPath(backing, "local.txt"), mtime, mtime);
	svc.setStateForTest(driveId, "f-local", "local.txt", HydrationState.hydrated);

	auto queue = new OnDemandChangeQueue();
	startOnDemandMount(db, svc, queue, thisTid, mnt, backing, driveId, "root");
	writeln("READY");
	stdout.flush();

	import core.time : MonoTime;
	struct Due { MonoTime at; OnDemandLocalChange change; }
	Due[] due;
	string stopFile = buildPath(work, "stop");
	while (!exists(stopFile)) {
		receiveTimeout(dur!"msecs"(100), (OnDemandWake w) {
			foreach (c; queue.drain()) {
				if (c.oldPath is null) writeln("EVENT ", c.kind, " ", c.path);
				else writeln("EVENT ", c.kind, " ", c.oldPath, " -> ", c.path);
				if (c.kind == OnDemandChangeKind.moved && ((c.oldPath.length > 8 && c.oldPath[0 .. 8] == "./apply/")
						|| (c.oldPath.length > 4 && c.oldPath[$ - 4 .. $] == ".tmp")
						|| (c.oldPath.length > 7 && c.oldPath[0 .. 7] == "./etag/")))
					due ~= Due(MonoTime.currTime + dur!"seconds"(1), c);
			}
			stdout.flush();
		});
		// Test controls: <work>/ctl/<command>-<id>[-<state>]
		string ctl = buildPath(work, "ctl");
		if (exists(ctl)) {
			foreach (entry; dirEntries(ctl, SpanMode.shallow)) {
				import std.string : split;
				auto parts = baseName(entry.name).split("~");
				if (parts[0] == "defer") svc.deferForTest(driveId, parts[1]);
				if (parts[0] == "transient") svc.setTransientForTest(driveId, parts[1], parts[2].to!OnDemandTransientState);
				remove(entry.name);
				writeln("CTL ", baseName(entry.name));
			}
		}
		// The client logger writes to the same buffered stdout
		stdout.flush();
		while (due.length && due[0].at <= MonoTime.currTime) {
			auto c = due[0].change;
			due = due[1 .. $];
			Item item, parent;
			if (c.oldPath[0 .. 7] != "./apply") {
				// The engine uploaded the new content of the destination item
				if (db.selectByPath(c.path, driveId, item)) {
					item.eTag = item.eTag ~ "+";
					db.update(item);
					writeln("CHANGED ", c.path);
				} else {
					writeln("CHANGE FAILED ", c.path);
				}
				stdout.flush();
				continue;
			}
			if (db.selectByPath(c.oldPath, driveId, item) && db.selectByPath(dirName(c.path), driveId, parent)) {
				item.name = baseName(c.path);
				item.parentId = parent.id;
				db.update(item);
				writeln("APPLIED ", c.oldPath, " -> ", c.path);
			} else {
				writeln("APPLY FAILED ", c.oldPath, " -> ", c.path);
			}
			stdout.flush();
		}
	}
	foreach (id; ["f-big", "f-trunc", "f-move", "f-pin", "f-write"])
		writeln("DOWNLOADS ", id, " ", svc.downloadCount(driveId, id));
	svc.shutdown();
	stopOnDemandMount();
	writeln("STOPPED");
	stdout.flush();
	db.closeDatabaseFile();
}
