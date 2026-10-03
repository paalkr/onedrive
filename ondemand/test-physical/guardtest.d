/*
 * Offline changes of the physical sync_dir that must not reach OneDrive, checked with the real
 * SyncEngine consistency check (no network: the queued online deletes are only counted, and the
 * guard decides whether any of them would be sent).
 *   G1 sync_dir emptied (rm -rf of the physical tree): the start is refused, and the deletes of the
 *      pass are refused as a big delete
 *   G2 many files deleted while others remain: refused as a big delete
 *   G3 a folder of many files deleted: refused as a big delete
 *   G4 a few files deleted: the deletes go through
 *   G5 an older copy put at the path of an online-only file: kept as a conflict copy, not uploaded
 *   G6 a copy with the online content at the path of an online-only file: hydrated, not uploaded
 *   G7 control: a change of an online-only file written after the start is still uploaded
 *   G8 a relative symbolic link is resolved against its own directory (no chdir)
 *   G9, G10 content created through the mount over an online-only file (O_TRUNC, saved by rename),
 *      then a stop before the upload: uploaded under its own name at the next start
 * Usage: guardtest <work dir>
 */
import std.stdio, std.file, std.path, std.datetime, std.conv, std.algorithm;
import config, itemdb, hydration, log, syncEngine, clientSideFiltering, util;

int failures;
void check(bool ok, string name) {
	writeln(ok ? "PASS " : "FAIL ", name);
	if (!ok) failures++;
}

enum long bigDelete = 10;
enum int docFiles = 30;

struct Setup {
	ApplicationConfig cfg;
	ItemDatabase db;
	string sync;
}

// A profile with: root, docs/ (30 hydrated files), pinned.txt (P), odir/ (online-only files) and
// online.txt (O, content "online version"). Every hydrated and pinned file exists physically.
Setup make(string work) {
	auto mtime = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
	Setup s;
	string conf = buildPath(work, "conf");
	s.sync = buildPath(work, "sync");
	mkdirRecurse(conf);
	mkdirRecurse(buildPath(s.sync, "docs"));
	mkdirRecurse(buildPath(s.sync, "odir"));
	std.file.write(buildPath(conf, "config"), "sync_dir = \"" ~ s.sync ~ "\"\n");
	s.cfg = new ApplicationConfig();
	s.cfg.initialise(conf, false);
	s.cfg.setValueBool("on_demand", true);
	s.cfg.setValueBool("monitor", true);
	s.cfg.setValueLong("classify_as_big_delete", bigDelete);
	s.cfg.setValueBool("force", false);   // a command line option, not in the config file
	s.cfg.defaultDriveId = "d1";
	s.db = new ItemDatabase(buildPath(work, "items.sqlite3"));
	void add(string id, string parent, string name, ItemType type, string state, string content = null) {
		Item it = { driveId: "d1", id: id, name: name, type: type, mtime: mtime, parentId: parent, syncStatus: "Y", eTag: "e" ~ id };
		string path = parent is null ? s.sync : buildPath(s.sync, s.db.computePath("d1", parent), name);
		if (content !is null) {
			// The hash is that of the online content; hydrated files also have it locally
			string tmp = buildPath(work, "hash.tmp");
			std.file.write(tmp, content);
			it.quickXorHash = computeQuickXorHash(tmp);
			it.size = to!string(content.length);
			std.file.remove(tmp);
			if (state != "O") {
				std.file.write(path, content);
				setTimes(path, mtime, mtime);
			}
		}
		if (state !is null) setItemHydration(it, state);
		s.db.insert(it);
	}
	add("root", null, "root", ItemType.root, null);
	add("D", "root", "docs", ItemType.dir, null);
	foreach (i; 0 .. docFiles) add("H" ~ to!string(i), "D", "f" ~ to!string(i) ~ ".txt", ItemType.file, "H", "content " ~ to!string(i));
	add("P", "root", "pinned.txt", ItemType.file, "P", "pinned content");
	add("OD", "root", "odir", ItemType.dir, "O");
	add("O1", "OD", "o1.txt", ItemType.file, "O", "online one");
	add("O", "root", "online.txt", ItemType.file, "O", "online version");
	return s;
}

// The consistency check of one pass over the database, as performDatabaseConsistencyAndIntegrityCheck runs it
SyncEngine runPass(Setup s) {
	chdir(s.sync);
	auto engine = new SyncEngine(s.cfg, s.db, new ClientSideFiltering(s.cfg));
	foreach (item; s.db.selectByDriveId("d1")) engine.checkDatabaseItemForConsistency(item);
	return engine;
}

long validDeletes(SyncEngine engine) {
	long n;
	foreach (q; engine.databaseItemsToDeleteOnline) if (engine.onDemandLocalDeletionStillValid(q.dbItem, q.localFilePath)) n++;
	return n;
}

void main(string[] args) {
	initialiseLogging(false, false);
	scope(exit) shutdownLogging();
	string work = args[1];
	string cwd = getcwd();
	scope(exit) chdir(cwd);

	{
		auto s = make(buildPath(work, "g1"));
		rmdirRecurse(s.sync);
		mkdir(s.sync);
		chdir(s.sync);
		auto engine = new SyncEngine(s.cfg, s.db, new ClientSideFiltering(s.cfg));
		long missing = engine.onDemandRecordedLocalFilesAllMissing();
		check(missing == docFiles + 1, "G1 emptied sync_dir: the start is refused (" ~ to!string(missing) ~ " hydrated or pinned files missing)");
		foreach (item; s.db.selectByDriveId("d1")) engine.checkDatabaseItemForConsistency(item);
		check(!engine.onDemandQueuedOnlineDeletesAllowed(), "G1 emptied sync_dir: the queued online deletes are refused as a big delete");
		check(exists(buildPath(s.sync, "odir")), "G1 the folder of online-only files is recreated, not deleted");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	{
		auto s = make(buildPath(work, "g2"));
		foreach (i; 0 .. 12) std.file.remove(buildPath(s.sync, "docs", "f" ~ to!string(i) ~ ".txt"));
		chdir(s.sync);
		auto engine = new SyncEngine(s.cfg, s.db, new ClientSideFiltering(s.cfg));
		check(engine.onDemandRecordedLocalFilesAllMissing() == 0, "G2 some files remain: the start is not refused");
		foreach (item; s.db.selectByDriveId("d1")) engine.checkDatabaseItemForConsistency(item);
		check(validDeletes(engine) == 12, "G2 12 files deleted one by one are queued (" ~ to!string(validDeletes(engine)) ~ ")");
		check(!engine.onDemandQueuedOnlineDeletesAllowed(), "G2 their total reaches classify_as_big_delete (10): none is sent");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	{
		auto s = make(buildPath(work, "g3"));
		rmdirRecurse(buildPath(s.sync, "docs"));
		auto engine = runPass(s);
		check(!engine.onDemandQueuedOnlineDeletesAllowed(), "G3 a deleted folder counts with its files: refused as a big delete");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	{
		auto s = make(buildPath(work, "g4"));
		foreach (i; 0 .. 3) std.file.remove(buildPath(s.sync, "docs", "f" ~ to!string(i) ~ ".txt"));
		auto engine = runPass(s);
		check(validDeletes(engine) == 3 && engine.onDemandQueuedOnlineDeletesAllowed(), "G4 3 deliberate deletes go through");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	{
		auto s = make(buildPath(work, "g5"));
		string target = buildPath(s.sync, "online.txt");
		std.file.write(target, "an older copy");
		setTimes(target, SysTime(DateTime(2020, 1, 1), UTC()), SysTime(DateTime(2020, 1, 1), UTC()));
		import core.thread : Thread;
		import core.time : dur;
		Thread.sleep(dur!"msecs"(1100));   // the copy was put there before the engine started
		auto engine = runPass(s);
		Item o;
		s.db.selectById("d1", "O", o);
		string[] copies;
		foreach (e; dirEntries(s.sync, SpanMode.shallow)) if (baseName(e.name).startsWith("online-") && e.name.endsWith(".txt")) copies ~= e.name;
		check(!exists(target) && copies.length == 1 && readText(copies[0]) == "an older copy", "G5 older copy over an online-only file kept as a conflict copy " ~ to!string(copies.map!baseName));
		check(engine.databaseItemsWhereContentHasChanged.length == 0 && o.hydration == "O", "G5 nothing is uploaded over the online version, the item stays online-only");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	{
		auto s = make(buildPath(work, "g6"));
		string target = buildPath(s.sync, "online.txt");
		std.file.write(target, "online version");
		import core.thread : Thread;
		import core.time : dur;
		Thread.sleep(dur!"msecs"(1100));
		auto engine = runPass(s);
		Item o;
		s.db.selectById("d1", "O", o);
		check(exists(target) && readText(target) == "online version" && o.hydration == "H", "G6 a copy with the online content is hydrated in place");
		check(engine.databaseItemsWhereContentHasChanged.length == 0, "G6 nothing is uploaded");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	{
		// A write through the mount after the start (a pending local change of an online-only file) is still uploaded
		auto s = make(buildPath(work, "g7"));
		chdir(s.sync);
		auto engine = new SyncEngine(s.cfg, s.db, new ClientSideFiltering(s.cfg));
		import core.thread : Thread;
		import core.time : dur;
		Thread.sleep(dur!"msecs"(1100));
		std.file.write(buildPath(s.sync, "online.txt"), "edited through the mount");
		foreach (item; s.db.selectByDriveId("d1")) engine.checkDatabaseItemForConsistency(item);
		check(engine.databaseItemsWhereContentHasChanged.length == 1 && exists(buildPath(s.sync, "online.txt")), "G7 a change written after the start is still queued for upload, no conflict copy");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	{
		// Finding 3: a relative symbolic link is resolved against its own directory, without chdir
		auto s = make(buildPath(work, "g8"));
		mkdirRecurse(buildPath(s.sync, "links"));
		std.file.write(buildPath(s.sync, "target.txt"), "target");
		symlink("../target.txt", buildPath(s.sync, "links", "relative.txt"));
		symlink("../missing.txt", buildPath(s.sync, "links", "dangling.txt"));
		chdir(s.sync);
		auto filtering = new ClientSideFiltering(s.cfg);
		filtering.initialise();   // the skip_file/skip_dir rules are checked after the symlink rule
		auto engine = new SyncEngine(s.cfg, s.db, filtering);
		string before = getcwd();
		bool relativeExcluded = engine.checkPathAgainstClientSideFiltering("links/relative.txt");
		bool danglingExcluded = engine.checkPathAgainstClientSideFiltering("links/dangling.txt");
		check(!relativeExcluded && danglingExcluded, "G8 relative symlink resolved against its directory: valid kept, dangling skipped");
		check(getcwd() == before, "G8 the working directory is unchanged");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	foreach (how; ["createEmpty", "saved by rename"]) {
		// N1: content the mount created over an online-only file, then a stop before the upload. At
		// the next start it is a modified hydrated file: uploaded under its own name, no conflict copy.
		string tag = how == "createEmpty" ? "G9" : "G10";
		auto s = make(buildPath(work, tag == "G9" ? "g9" : "g10"));
		string target = buildPath(s.sync, "online.txt");
		auto svc = new HydrationService(s.cfg, s.db, s.sync);
		if (how == "createEmpty") {
			svc.createEmpty("d1", "O");
			std.file.write(target, "edited through the mount");
		} else {
			std.file.write(buildPath(s.sync, "save.tmp"), "edited through the mount");
			rename(buildPath(s.sync, "save.tmp"), target);
			svc.noteLocalContent("d1", "O");
		}
		Item o;
		s.db.selectById("d1", "O", o);
		check(o.hydration == "H", tag ~ " " ~ how ~ " over an online-only file: state H at once");
		svc.shutdown();
		import core.thread : Thread;
		import core.time : dur;
		Thread.sleep(dur!"msecs"(1100));   // the client stopped; this is the next start
		auto engine = runPass(s);
		bool queued = engine.databaseItemsWhereContentHasChanged.length == 1 && engine.databaseItemsWhereContentHasChanged[0][1] == "O";
		bool copies = false;
		foreach (e; dirEntries(s.sync, SpanMode.shallow)) if (baseName(e.name).startsWith("online-")) copies = true;
		check(queued && !copies && readText(target) == "edited through the mount", tag ~ " after the restart it is queued for upload under its own name, no conflict copy");
		engine.shutdownProcessPool();
		s.db.closeDatabaseFile();
	}
	writeln(failures == 0 ? "guardtest done" : "guardtest failures: " ~ to!string(failures));
}
