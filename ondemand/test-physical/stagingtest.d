/*
 * Crash between staging and rename: a hydration download left in the staging directory of the
 * physical sync_dir is removed when HydrationService starts, and the item keeps its online-only
 * state (the state is only set after the rename into place). Usage: stagingtest <work dir>
 */
import std.stdio, std.file, std.path;
import config, itemdb, hydration, log;

void main(string[] args) {
	initialiseLogging(false, false);
	scope(exit) shutdownLogging();
	string work = args[1];
	string confdir = buildPath(work, "conf");
	string syncDir = buildPath(work, "sync");
	mkdirRecurse(confdir);
	mkdirRecurse(buildPath(syncDir, onDemandStagingDirName));
	std.file.write(buildPath(syncDir, onDemandStagingDirName, "d1_O"), "half a download");
	std.file.write(buildPath(syncDir, onDemandStagingDirName, "d1_O.partial"), "half");
	auto appConfig = new ApplicationConfig();
	appConfig.initialise(confdir, false);
	auto db = new ItemDatabase(buildPath(work, "items.sqlite3"));
	import std.datetime;
	Item root = { driveId: "d1", id: "root", name: "root", type: ItemType.root, mtime: SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC()), syncStatus: "Y" };
	db.insert(root);
	Item o = { driveId: "d1", id: "O", name: "online.txt", type: ItemType.file, parentId: "root", mtime: SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC()), syncStatus: "Y", size: "5", eTag: "e" };
	setItemHydration(o, "O");
	db.insert(o);
	auto svc = new HydrationService(appConfig, db, syncDir);
	bool cleaned = exists(buildPath(syncDir, onDemandStagingDirName)) && (dirEntries(buildPath(syncDir, onDemandStagingDirName), SpanMode.shallow).empty);
	Item after;
	db.selectById("d1", "O", after);
	writeln(cleaned ? "PASS S1 interrupted staging downloads removed at start" : "FAIL S1 staging not cleaned");
	writeln(after.hydration == "O" ? "PASS S1 item still online-only" : "FAIL S1 state " ~ after.hydration);
	writeln(!exists(buildPath(syncDir, "online.txt")) ? "PASS S1 no partial file at the item path" : "FAIL S1 file at item path");
	svc.shutdown();
	db.closeDatabaseFile();
}
