import std.stdio, std.file, std.path, std.datetime;
import itemdb, ondemandpins, log;

Item mk(string drive, string id, string parent, string name, ItemType type, string hydration) {
	Item it;
	it.driveId = drive; it.id = id; it.parentId = parent; it.name = name; it.type = type;
	it.mtime = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
	it.syncStatus = "Y";
	if (hydration !is null) setItemHydration(it, hydration);
	return it;
}

void main(string[] args) {
	initialiseLogging(false, false);
	scope(exit) shutdownLogging();
	string dir = args[1];
	string dbPath = buildPath(dir, "items.sqlite3");
	string pins = onDemandPinsFile(dir);
	{
		auto db = new ItemDatabase(dbPath);
		Item root = mk("d1", "root", null, "root", ItemType.root, null); db.insert(root);
		Item a = mk("d1", "A", "root", "Pinned", ItemType.dir, "P"); db.insert(a);
		Item f = mk("d1", "F1", "A", "keep.txt", ItemType.file, "P"); db.insert(f);
		Item g = mk("d1", "G1", "root", "renamed-id.txt", ItemType.file, "P"); db.insert(g);
		Item h = mk("d1", "H1", "root", "plain.txt", ItemType.file, "H"); db.insert(h);
		writeln("saved: ", saveOnDemandPins(db, pins));
		db.closeDatabaseFile();
	}
	std.file.remove(dbPath);
	{
		// The resync rebuilds the database without hydration states; G1 comes back with a new id
		auto db = new ItemDatabase(dbPath);
		Item root = mk("d1", "root", null, "root", ItemType.root, null); db.insert(root);
		Item a = mk("d1", "A", "root", "Pinned", ItemType.dir, null); db.insert(a);
		Item f = mk("d1", "F1", "A", "keep.txt", ItemType.file, null); db.insert(f);
		Item g = mk("d1", "G2", "root", "renamed-id.txt", ItemType.file, null); db.insert(g);
		Item h = mk("d1", "H1", "root", "plain.txt", ItemType.file, null); db.insert(h);
		auto records = loadOnDemandPins(pins);
		writeln("records: ", records.length);
		foreach (r; records) writeln("  ", r.driveId, " ", r.id, " ", r.path, " dir=", r.isDirectory);
		auto items = resolveOnDemandPins(db, records, "d1");
		string[] ids; foreach (it; items) ids ~= it.id;
		writeln("resolved ids: ", ids);
		bool ok = (records.length == 3) && (ids.length == 3) && (ids[0] == "A" || ids.length) ;
		import std.algorithm : sort, equal;
		ids.sort();
		writeln((equal(ids, ["A", "F1", "G2"])) ? "PASS pins resolve by id and by path" : "FAIL");
		db.closeDatabaseFile();
	}
}
