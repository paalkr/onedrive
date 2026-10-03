/*
 * Ranged reads of the real HydrationService (background readers), with an injected URL source and
 * fetch instead of Graph:
 *   R1 a 4 KB read is one request for one 128 KiB block, with the right bytes
 *   R2 later and concurrent reads of cached blocks make no request
 *   R3 a read past the end is clamped, past the size returns nothing
 *   R4 an expired download URL (403) is fetched again once and the read succeeds
 *   R5 offline: EIO, and further reads fail at once without a request (back-off)
 *   R6 an item gone online (404): ENOENT
 *   R7 OneDriveApi.downloadRangeByUrl against a local HTTP server: 206 with the right bytes, a server
 *      that ignores Range (200), past the end (416), an expired URL (403 throws with the status)
 * Usage: rangetest <work dir>
 */
import std.stdio, std.file, std.path, std.datetime, std.conv, std.algorithm;
import core.thread, core.time, core.atomic;
import core.stdc.errno;
import config, itemdb, hydration, log, onedrive;

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
	Item f = { driveId: "d1", id: "F", name: "big.bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
	setItemHydration(f, "O");
	db.insert(f);

	ubyte[] content;
	foreach (i; 0 .. 600_000) content ~= cast(ubyte) (i * 7);
	shared int urlCalls, fetchCalls;
	bool offline, gone;
	int expireNext;   // fetches to answer with 403
	auto svc = new HydrationService(cfg, db, sync);
	svc.rangeUrlSource = (string driveId, string id, out long size) {
		atomicOp!"+="(urlCalls, 1);
		if (offline) throw new RangeFetchError(0, "not reachable");
		if (gone) throw new RangeFetchError(404, "gone");
		size = content.length;
		return "https://fake/download/" ~ to!string(atomicLoad(urlCalls));
	};
	svc.rangeFetch = (string url, ulong offset, size_t length) {
		atomicOp!"+="(fetchCalls, 1);
		if (offline) throw new RangeFetchError(0, "not reachable");
		if (expireNext > 0) { expireNext--; throw new RangeFetchError(403, "expired"); }
		Thread.sleep(50.msecs);
		if (offset >= content.length) return cast(ubyte[]) [];
		ulong end = min(offset + length, content.length);
		return content[cast(size_t) offset .. cast(size_t) end].dup;
	};

	auto data = svc.readRange("d1", "F", 1000, 4096);
	check(data == content[1000 .. 5096] && atomicLoad(fetchCalls) == 1 && atomicLoad(urlCalls) == 1, "R1 a 4 KB read: one request, the right bytes");

	data = svc.readRange("d1", "F", 60_000, 4096);
	Thread[] readers;
	shared int good;
	foreach (i; 0 .. 8) {
		readers ~= new Thread({
			auto d = svc.readRange("d1", "F", 10_000, 65_536);
			if (d == content[10_000 .. 75_536]) atomicOp!"+="(good, 1);
		});
		readers[$ - 1].start();
	}
	foreach (r; readers) r.join();
	check(atomicLoad(fetchCalls) == 1 && atomicLoad(good) == 8, "R2 later and 8 concurrent reads of the cached block: no new request");

	data = svc.readRange("d1", "F", 599_000, 4096);
	auto past = svc.readRange("d1", "F", 700_000, 10);
	check(data == content[599_000 .. $] && past.length == 0, "R3 a read past the end is clamped, past the size returns nothing");

	expireNext = 1;
	int urlsBefore = atomicLoad(urlCalls);
	data = svc.readRange("d1", "F", 140_000, 100);
	check(data == content[140_000 .. 140_100] && atomicLoad(urlCalls) == urlsBefore + 1, "R4 an expired download URL (403) is fetched again once, the read succeeds");

	offline = true;
	string error;
	int errnoCode;
	try svc.readRange("d1", "F", 450_000, 100); catch (HydrationError e) { error = e.msg; errnoCode = e.errnoCode; }
	int fetchesAfterFirst = atomicLoad(fetchCalls);
	auto t0 = MonoTime.currTime;
	int secondErrno;
	try svc.readRange("d1", "F", 460_000, 100); catch (HydrationError e) secondErrno = e.errnoCode;
	auto took = (MonoTime.currTime - t0).total!"msecs";
	check(errnoCode == EIO && secondErrno == EIO && atomicLoad(fetchCalls) == fetchesAfterFirst && took < 50, "R5 offline: EIO, then EIO at once without a request (" ~ to!string(took) ~ " ms)");
	offline = false;

	// A second item, after the back-off
	Item g = { driveId: "d1", id: "G", name: "gone.bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
	setItemHydration(g, "O");
	db.insert(g);
	Thread.sleep(dur!"seconds"(16));
	gone = true;
	errnoCode = 0;
	try svc.readRange("d1", "G", 0, 100); catch (HydrationError e) errnoCode = e.errnoCode;
	check(errnoCode == ENOENT, "R6 an item gone online: ENOENT");

	// R7: the curl path, against a local server
	{
		import std.process : spawnProcess, Config, kill, wait, environment;
		import std.string : strip;
		string served = buildPath(work, "served.bin");
		std.file.write(served, content[0 .. 300_000]);
		string script = buildPath(work, "server.py");
		std.file.write(script, `import http.server, os, re, sys
data = open(sys.argv[1], "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/expired":
            self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers(); return
        m = re.match(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if self.path == "/norange" or not m:
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        a, b = int(m.group(1)), int(m.group(2))
        if a >= len(data):
            self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
        part = data[a:b + 1]
        self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (a, a + len(part) - 1, len(data)))
        self.send_header("Content-Length", str(len(part))); self.end_headers(); self.wfile.write(part)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
`);
		string portFile = buildPath(work, "port");
		auto server = spawnProcess(["python3", script, served, portFile]);
		scope(exit) { kill(server); wait(server); }
		foreach (i; 0 .. 50) { if (exists(portFile) && readText(portFile).strip.length) break; Thread.sleep(100.msecs); }
		string base = "http://127.0.0.1:" ~ readText(portFile).strip;
		environment["no_proxy"] = "127.0.0.1";
		// Command line options (not in the config file), and a fake refresh token so initialise() does
		// not try to authenticate; the ranged request carries no Authorization header anyway
		foreach (option; ["monitor", "dry_run", "use_device_auth", "read_only_auth_scope", "use_intune_sso"])
			if (!cfg.boolValues.get(option, false)) cfg.setValueBool(option, false);
		std.file.write(cfg.refreshTokenFilePath, "fake-refresh-token");
		auto api = new OneDriveApi(cfg);
		api.initialise();
		auto ranged = api.downloadRangeByUrl(base ~ "/f", 1000, 4096);
		auto ignored = api.downloadRangeByUrl(base ~ "/norange", 1000, 4096);
		auto tail = api.downloadRangeByUrl(base ~ "/f", 299_000, 4096);
		auto beyond = api.downloadRangeByUrl(base ~ "/f", 400_000, 10);
		int status;
		try api.downloadRangeByUrl(base ~ "/expired", 0, 10); catch (OneDriveException e) status = e.httpStatusCode;
		api.releaseCurlEngine();
		check(ranged == content[1000 .. 5096] && ignored == content[1000 .. 5096] && tail == content[299_000 .. 300_000] && beyond.length == 0 && status == 403,
			"R7 downloadRangeByUrl: 206, 200 without Range, clamped tail, 416 past the end, 403 throws with the status");
	}

	svc.shutdown();
	db.closeDatabaseFile();
	writeln(failures == 0 ? "rangetest done" : "rangetest failures: " ~ to!string(failures));
}
