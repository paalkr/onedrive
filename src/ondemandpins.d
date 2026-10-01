// What is this module called?
module ondemandpins;

// What does this module require to function?
import std.algorithm;
import std.file;
import std.json;
import std.path;
import std.string;

// What other modules that we have created do we need to import?
import itemdb;
import log;

// Pins ("Always keep on this device") survive --resync in on-demand mode: before the resync
// removes the item database, every pinned item is recorded in a file in the confdir; after the
// first sync cycle has rebuilt the database, the records are resolved to the new items (by id,
// else by path) and pinned again.

struct OnDemandPinRecord {
	string driveId;
	string id;
	string path;      // relative to the sync directory, fallback when the id is gone
	bool isDirectory;
}

string onDemandPinsFile(string configDir) {
	return buildPath(configDir, ".ondemand-resync-pins.json");
}

// Record the pinned items of 'db' in 'file'. Returns the number recorded (0: no file written).
size_t saveOnDemandPins(ItemDatabase db, string file) {
	OnDemandPinRecord[] records;
	foreach (item; db.selectPinnedItems()) {
		string path;
		try {
			path = db.computePath(item.driveId, item.id);
		} catch (Throwable e) {
			path = null;
		}
		records ~= OnDemandPinRecord(item.driveId, item.id, path, (item.type == ItemType.dir) || (item.type == ItemType.root));
	}
	if (records.length == 0) {
		if (exists(file)) std.file.remove(file);
		return 0;
	}
	JSONValue[] array;
	foreach (record; records) {
		array ~= JSONValue(["driveId": JSONValue(record.driveId), "id": JSONValue(record.id), "path": JSONValue(record.path), "isDirectory": JSONValue(record.isDirectory)]);
	}
	string temporary = file ~ ".tmp";
	std.file.write(temporary, JSONValue(array).toString());
	rename(temporary, file);
	return records.length;
}

OnDemandPinRecord[] loadOnDemandPins(string file) {
	OnDemandPinRecord[] records;
	if (!exists(file)) return records;
	JSONValue json = parseJSON(readText(file));
	if (json.type != JSONType.array) return records;
	foreach (entry; json.array) {
		if (entry.type != JSONType.object) continue;
		OnDemandPinRecord record;
		record.driveId = ("driveId" in entry) ? entry["driveId"].str : null;
		record.id = ("id" in entry) ? entry["id"].str : null;
		record.path = (("path" in entry) && (entry["path"].type == JSONType.string)) ? entry["path"].str : null;
		record.isDirectory = ("isDirectory" in entry) && (entry["isDirectory"].type == JSONType.true_);
		records ~= record;
	}
	return records;
}

// The current database items for the records: by id, else by path. Unresolvable records are logged.
Item[] resolveOnDemandPins(ItemDatabase db, OnDemandPinRecord[] records, string rootDriveId) {
	Item[] items;
	foreach (record; records) {
		Item item;
		if (!record.id.empty && db.selectById(record.driveId, record.id, item)) {
			items ~= item;
		} else if (!record.path.empty && db.selectByPath(record.path, rootDriveId, item)) {
			items ~= item;
		} else {
			addLogEntry("On-demand: a pinned item from before the resync no longer exists: " ~ record.path);
		}
	}
	return items;
}
