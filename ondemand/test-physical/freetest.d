/*
 * "Free up space" and on-access scanners, with the real HydrationService: a file open only by a
 * scanner is freed once the scanner closes it (within 5 s); a user handle refuses at once; a
 * scanner that keeps the file open gets EBUSY after about 5 s. Usage: freetest <work dir>
 */
import std.stdio, std.file, std.path, std.datetime, std.conv;
import core.thread, core.time;
import config, itemdb, hydration, log, util;

int failures;
void check(bool ok, string name) {
	writeln(ok ? "PASS " : "FAIL ", name);
	if (!ok) failures++;
}

void main(string[] args) {
	initialiseLogging(false, false);
	scope(exit) shutdownLogging();
	string work = args[1];
	string conf = buildPath(work, "conf");
	string sync = buildPath(work, "sync");
	mkdirRecurse(conf);
	mkdirRecurse(sync);
	auto cfg = new ApplicationConfig();
	cfg.initialise(conf, false);
	auto db = new ItemDatabase(buildPath(work, "items.sqlite3"));
	auto mtime = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
	Item root = { driveId: "d1", id: "root", name: "root", type: ItemType.root, mtime: mtime, syncStatus: "Y" };
	db.insert(root);
	string path = buildPath(sync, "f.txt");
	Item f = { driveId: "d1", id: "F", name: "f.txt", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
	void hydrated() {
		std.file.write(path, "content");
		setTimes(path, mtime, mtime);
		f.quickXorHash = computeQuickXorHash(path);
		f.size = "7";
		setItemHydration(f, "H");
		db.upsert(f);
	}
	string state() { Item it; db.selectById("d1", "F", it); return it.hydration; }
	hydrated();
	auto svc = new HydrationService(cfg, db, sync);

	// A scanner handle closed after 1 s
	svc.noteOpen("d1", "F", true);
	auto closer = new Thread({ Thread.sleep(1.seconds); svc.noteClose("d1", "F", true); });
	closer.start();
	auto t0 = MonoTime.currTime;
	string error;
	try svc.requestAction("d1", "F", OnDemandAction.free); catch (HydrationError e) error = e.msg;
	auto waited = (MonoTime.currTime - t0).total!"msecs";
	closer.join();
	check(error is null && state() == "O" && !exists(path) && waited >= 800, "F1 open only by a scanner: free waits for it, then frees (" ~ to!string(waited) ~ " ms)");

	// A user handle, and a scanner handle together with it
	hydrated();
	svc.noteOpen("d1", "F", false);
	svc.noteOpen("d1", "F", true);
	t0 = MonoTime.currTime;
	error = null;
	try svc.requestAction("d1", "F", OnDemandAction.free); catch (HydrationError e) error = e.msg;
	waited = (MonoTime.currTime - t0).total!"msecs";
	check(error !is null && state() == "H" && exists(path) && waited < 500, "F2 a user handle (with a scanner handle): EBUSY at once (" ~ to!string(waited) ~ " ms)");
	svc.noteClose("d1", "F", false);

	// Only the scanner handle is left, and it stays open
	t0 = MonoTime.currTime;
	error = null;
	try svc.requestAction("d1", "F", OnDemandAction.free); catch (HydrationError e) error = e.msg;
	waited = (MonoTime.currTime - t0).total!"msecs";
	check(error !is null && state() == "H" && waited >= 4500 && waited < 7000, "F3 a scanner that keeps the file open: EBUSY after about 5 s (" ~ to!string(waited) ~ " ms)");
	svc.noteClose("d1", "F", true);

	svc.shutdown();
	db.closeDatabaseFile();
	writeln(failures == 0 ? "freetest done" : "freetest failures: " ~ to!string(failures));
}
