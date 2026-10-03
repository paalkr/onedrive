/*
 * Creates an item database for the physical sync_dir tests:
 *   root, folder "docs" (pinned), files: docs/hydrated.txt (H), docs/online.txt (O),
 *   pinned.txt (P), plain.txt (no state). Usage: mkdb <database file>
 */
import std.datetime;
import itemdb, log;

void main(string[] args) {
	initialiseLogging(false, false);
	scope(exit) shutdownLogging();
	auto db = new ItemDatabase(args[1]);
	auto mtime = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
	void add(string id, string parent, string name, ItemType type, string state) {
		Item it = { driveId: "d1", id: id, name: name, type: type, mtime: mtime, parentId: parent, syncStatus: "Y", size: "5", eTag: "e" ~ id };
		if (state !is null) setItemHydration(it, state);
		db.insert(it);
	}
	add("root", null, "root", ItemType.root, null);
	add("D", "root", "docs", ItemType.dir, "P");
	add("H", "D", "hydrated.txt", ItemType.file, "H");
	add("O", "D", "online.txt", ItemType.file, "O");
	add("P", "root", "pinned.txt", ItemType.file, "P");
	add("N", "root", "plain.txt", ItemType.file, null);
	db.closeDatabaseFile();
}
