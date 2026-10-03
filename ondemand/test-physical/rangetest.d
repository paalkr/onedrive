/*
 * Ranged reads of the real HydrationService (background readers), with injected URL source, fetch
 * and probe instead of Graph:
 *   R1 a 4 KB read is one request for one 128 KiB block, with the right bytes
 *   R2 later and concurrent reads of cached blocks make no request
 *   R3 a read past the end is clamped, past the size returns nothing
 *   R4 an expired download URL (403) is fetched again once and the read succeeds
 *   R5 offline: EIO, and further reads fail at once without a request (back-off)
 *   R6 an item gone online (404): ENOENT
 *   R7 a new database version drops the cached blocks; an online version other than the requested
 *      one, or another size, is EIO
 *   R8 a short block before the end of the file is EIO, not the end of the file
 *   R9 one reachability probe serves reads of several items within a few seconds
 *   R12 cache accounting under eviction: 8 threads read 40 items with a 1 MiB cache limit; the byte
 *      count stays the sum of the cached items and within the limit, every read gets its bytes
 *   R10 OneDriveApi.downloadRangeByUrl against a local HTTP server: 206 with the right bytes, a server
 *      that ignores Range (200, cut off at the requested length even for an endless body), past the
 *      end (416), an expired URL (403), a 206 for another range (502), the overall timeout
 *   R11 shutdown aborts a ranged request in progress and does not wait for it
 *   R13 the total size in a range response must be the database size
 *   R14 a range response with another ETag than the cached blocks' is EIO and drops them
 *   R15 a cached block serves other handles only shortly after its fetch, its own handle always
 *   R16 no database size: the online size is used; with none at all a short block is the end
 *   R17 shutdown during a download-URL request waits for it and logs nothing afterwards
 * Usage: rangetest <work dir>
 */
import std.stdio, std.file, std.path, std.datetime, std.conv, std.algorithm;
import core.thread, core.time, core.atomic;
import core.stdc.errno;
import std.net.curl : CurlException;
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
	foreach (id; ["F", "G", "P1", "P2", "P3", "S"]) {
		Item f = { driveId: "d1", id: id, name: id ~ ".bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
		setItemHydration(f, "O");
		db.insert(f);
	}

	ubyte[] content;
	foreach (i; 0 .. 600_000) content ~= cast(ubyte) (i * 7);
	long size = content.length;
	shared int urlCalls, fetchCalls, probeCalls;
	bool offline, gone, shortBlock;
	string onlineVersion = "v1";
	long onlineSize = size;
	int expireNext;   // fetches to answer with 403
	auto svc = new HydrationService(cfg, db, sync);
	svc.rangeProbe = () { atomicOp!"+="(probeCalls, 1); return !offline; };
	svc.rangeUrlSource = (string driveId, string id, out long itemSize, out string itemVersion) {
		atomicOp!"+="(urlCalls, 1);
		if (offline) throw new RangeFetchError(0, "not reachable");
		if (gone) throw new RangeFetchError(404, "gone");
		itemSize = onlineSize;
		itemVersion = onlineVersion;
		return "https://fake/download/" ~ to!string(atomicLoad(urlCalls));
	};
	long fakeTotal = -2;      // -2: report the real size
	string fakeEtag;
	svc.rangeFetch = (string url, ulong offset, size_t length, out long total, out string etag) {
		atomicOp!"+="(fetchCalls, 1);
		total = (fakeTotal == -2) ? onlineSize : fakeTotal;
		etag = fakeEtag;
		if (offline) throw new RangeFetchError(0, "not reachable");
		if (expireNext > 0) { expireNext--; throw new RangeFetchError(403, "expired"); }
		Thread.sleep(50.msecs);
		if (offset >= content.length) return cast(ubyte[]) [];
		ulong end = min(offset + length, content.length);
		if (shortBlock) end -= 10;
		return content[cast(size_t) offset .. cast(size_t) end].dup;
	};

	auto data = svc.readRange("d1", "F", "v1", size, 1000, 4096, 1);
	check(data == content[1000 .. 5096] && atomicLoad(fetchCalls) == 1 && atomicLoad(urlCalls) == 1, "R1 a 4 KB read: one request, the right bytes");

	data = svc.readRange("d1", "F", "v1", size, 60_000, 4096, 1);
	Thread[] readers;
	shared int good;
	foreach (i; 0 .. 8) {
		readers ~= new Thread({
			auto d = svc.readRange("d1", "F", "v1", size, 10_000, 65_536, 1);
			if (d == content[10_000 .. 75_536]) atomicOp!"+="(good, 1);
		});
		readers[$ - 1].start();
	}
	foreach (r; readers) r.join();
	check(atomicLoad(fetchCalls) == 1 && atomicLoad(good) == 8, "R2 later and 8 concurrent reads of the cached block: no new request");

	data = svc.readRange("d1", "F", "v1", size, 599_000, 4096, 1);
	auto past = svc.readRange("d1", "F", "v1", size, 700_000, 10, 1);
	check(data == content[599_000 .. $] && past.length == 0, "R3 a read past the end is clamped, past the size returns nothing");

	expireNext = 1;
	int urlsBefore = atomicLoad(urlCalls);
	data = svc.readRange("d1", "F", "v1", size, 140_000, 100, 1);
	check(data == content[140_000 .. 140_100] && atomicLoad(urlCalls) == urlsBefore + 1, "R4 an expired download URL (403) is fetched again once, the read succeeds");

	// R7: versions
	onlineVersion = "v2";
	int fetchesBefore = atomicLoad(fetchCalls);
	data = svc.readRange("d1", "F", "v2", size, 1000, 4096, 1);
	check(data == content[1000 .. 5096] && atomicLoad(fetchCalls) == fetchesBefore + 1, "R7 a new database version drops the cached blocks of the old one");
	onlineVersion = "v3";
	int errnoCode;
	try svc.readRange("d1", "G", "v2", size, 0, 100, 1); catch (HydrationError e) errnoCode = e.errnoCode;
	check(errnoCode == EIO, "R7 the online file is another version than the database item: EIO");
	onlineVersion = "v2";
	onlineSize = size + 1;
	errnoCode = 0;
	try svc.readRange("d1", "G", "v2", size, 0, 100, 1); catch (HydrationError e) errnoCode = e.errnoCode;
	check(errnoCode == EIO, "R7 the online size differs from the database item: EIO");
	onlineSize = size;

	// R8: a short block
	shortBlock = true;
	errnoCode = 0;
	try svc.readRange("d1", "S", "v2", size, 0, 100, 1); catch (HydrationError e) errnoCode = e.errnoCode;
	shortBlock = false;
	check(errnoCode == EIO, "R8 a short block before the end of the file: EIO");

	// R9: one probe for a folder listing (the probe is reused for 5 s)
	Thread.sleep(dur!"seconds"(6));
	int probesBefore = atomicLoad(probeCalls);
	foreach (id; ["P1", "P2", "P3"]) svc.readRange("d1", id, "v2", size, 0, 100, 1);
	check(atomicLoad(probeCalls) == probesBefore + 1, "R9 three items read within a few seconds: one reachability probe (" ~ to!string(atomicLoad(probeCalls) - probesBefore) ~ ")");

	// R12: accounting under eviction (pinned entries are never removed while they are read)
	{
		foreach (i; 0 .. 40) {
			Item it = { driveId: "d1", id: "C" ~ to!string(i), name: "c" ~ to!string(i), type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
			setItemHydration(it, "O");
			db.insert(it);
		}
		HydrationService.rangeCacheLimit = 1024 * 1024;
		shared int correct;
		Thread[] workers;
		foreach (w; 0 .. 8) {
			workers ~= new Thread({
				foreach (round; 0 .. 3)
					foreach (i; 0 .. 40) {
						auto d = svc.readRange("d1", "C" ~ to!string((i + w * 5) % 40), "v2", size, 200_000, 300_000, 1000 + w);
						if (d == content[200_000 .. 500_000]) atomicOp!"+="(correct, 1);
					}
			});
			workers[$ - 1].start();
		}
		foreach (t; workers) t.join();
		size_t items, bytes;
		bool consistent = svc.rangeCacheConsistentForTest(items, bytes);
		check(consistent && bytes <= 1024 * 1024 && atomicLoad(correct) == 8 * 3 * 40, "R12 cache accounting under eviction: " ~ to!string(items) ~ " items, " ~ to!string(bytes) ~ " bytes counted, all reads correct");
		HydrationService.rangeCacheLimit = 64 * 1024 * 1024;
	}

	// R13: Content-Range total against the database size
	{
		Item it = { driveId: "d1", id: "T", name: "t.bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
		setItemHydration(it, "O");
		db.insert(it);
		fakeTotal = size + 5;
		int code;
		try svc.readRange("d1", "T", "v2", size, 0, 100, 1); catch (HydrationError e) code = e.errnoCode;
		fakeTotal = -2;
		check(code == EIO, "R13 a range response for a file of another total size: EIO");
	}
	// R14: ETag of range responses
	{
		Item it = { driveId: "d1", id: "E", name: "e.bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
		setItemHydration(it, "O");
		db.insert(it);
		fakeEtag = "\"A\"";
		auto first = svc.readRange("d1", "E", "v2", size, 0, 100, 1);
		fakeEtag = "\"B\"";
		int code;
		try svc.readRange("d1", "E", "v2", size, 300_000, 100, 1); catch (HydrationError e) code = e.errnoCode;
		int fetchesBefore14 = atomicLoad(fetchCalls);
		fakeEtag = "\"A\"";
		auto again = svc.readRange("d1", "E", "v2", size, 0, 100, 1);
		fakeEtag = null;
		check(first == content[0 .. 100] && code == EIO && again == content[0 .. 100] && atomicLoad(fetchCalls) == fetchesBefore14 + 1,
			"R14 another ETag than the cached blocks': EIO, the blocks are dropped and fetched again");
	}
	// R15: sharing between handles
	{
		Item it = { driveId: "d1", id: "H", name: "h.bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
		setItemHydration(it, "O");
		db.insert(it);
		HydrationService.rangeShareTtl = dur!"seconds"(1);
		int f0 = atomicLoad(fetchCalls);
		svc.readRange("d1", "H", "v2", size, 0, 100, 101);
		svc.readRange("d1", "H", "v2", size, 0, 100, 102);   // another handle, within the share time
		int f1 = atomicLoad(fetchCalls);
		Thread.sleep(dur!"msecs"(1500));
		svc.readRange("d1", "H", "v2", size, 0, 100, 101);   // its own handle, later
		int f2 = atomicLoad(fetchCalls);
		svc.readRange("d1", "H", "v2", size, 0, 100, 103);   // a new handle, later
		int f3 = atomicLoad(fetchCalls);
		HydrationService.rangeShareTtl = dur!"seconds"(10);
		check((f1 == f0 + 1) && (f2 == f1) && (f3 == f2 + 1), "R15 a block serves another handle within the share time, its own handle later, a new handle later only after a new fetch");
	}
	// R16: unknown sizes
	{
		Item it = { driveId: "d1", id: "U", name: "u.bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
		setItemHydration(it, "O");
		db.insert(it);
		auto known = svc.readRange("d1", "U", "v2", -1, 599_000, 4096, 1);
		Item it2 = { driveId: "d1", id: "U2", name: "u2.bin", type: ItemType.file, parentId: "root", mtime: mtime, syncStatus: "Y", eTag: "e" };
		setItemHydration(it2, "O");
		db.insert(it2);
		onlineSize = -1;
		fakeTotal = -1;
		auto unknown = svc.readRange("d1", "U2", "v2", -1, 590_000, 20_000, 1);
		onlineSize = size;
		fakeTotal = -2;
		check(known == content[599_000 .. $] && unknown == content[590_000 .. $], "R16 no database size: the online size is used; no size at all: a short block is the end of the file");
	}

	// R5: offline
	offline = true;
	Thread.sleep(dur!"seconds"(6));   // the reused probe result expires
	errnoCode = 0;
	try svc.readRange("d1", "F", "v2", size, 450_000, 100, 1); catch (HydrationError e) errnoCode = e.errnoCode;
	int fetchesAfterFirst = atomicLoad(fetchCalls);
	auto t0 = MonoTime.currTime;
	int secondErrno;
	try svc.readRange("d1", "F", "v2", size, 460_000, 100, 1); catch (HydrationError e) secondErrno = e.errnoCode;
	auto took = (MonoTime.currTime - t0).total!"msecs";
	check(errnoCode == EIO && secondErrno == EIO && atomicLoad(fetchCalls) == fetchesAfterFirst && took < 50, "R5 offline: EIO, then EIO at once without a request (" ~ to!string(took) ~ " ms)");
	offline = false;

	// R6: gone online, after the back-off
	Thread.sleep(dur!"seconds"(16));
	gone = true;
	errnoCode = 0;
	try svc.readRange("d1", "G", "v2", size, 0, 100, 1); catch (HydrationError e) errnoCode = e.errnoCode;
	check(errnoCode == ENOENT, "R6 an item gone online: ENOENT");
	gone = false;

	// R10, R11: the curl path, against a local server
	{
		import std.process : spawnProcess, kill, wait, environment;
		import std.string : strip;
		string served = buildPath(work, "served.bin");
		std.file.write(served, content[0 .. 300_000]);
		string script = buildPath(work, "server.py");
		std.file.write(script, `import http.server, socketserver, re, sys, time
data = open(sys.argv[1], "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/expired":
            self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.path == "/endless":
            self.send_response(200); self.send_header("Content-Length", str(1 << 40)); self.end_headers()
            try:
                while True: self.wfile.write(b"x" * 65536)
            except Exception: return
        if self.path == "/slow":
            self.send_response(200); self.send_header("Content-Length", str(1 << 30)); self.end_headers()
            try:
                while True: self.wfile.write(b"y"); self.wfile.flush(); time.sleep(0.5)
            except Exception: return
        m = re.match(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if self.path == "/norange" or not m:
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        a, b = int(m.group(1)), int(m.group(2))
        if a >= len(data):
            self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
        start = a + 10 if self.path == "/badrange" else a
        part = data[start:b + 1]
        self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (start, start + len(part) - 1, len(data))); self.send_header("ETag", '"srv-1"')
        self.send_header("Content-Length", str(len(part))); self.end_headers(); self.wfile.write(part)
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
s = S(("127.0.0.1", 0), H)
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
		auto limit = dur!"seconds"(30);
		long tot;
		string tag;
		auto ranged = api.downloadRangeByUrl(base ~ "/f", 1000, 4096, limit, tot, tag);
		check(tot == 300_000 && tag == "\"srv-1\"", "R10 the total of Content-Range and the response ETag are reported (" ~ to!string(tot) ~ ", " ~ tag ~ ")");
		auto ignored = api.downloadRangeByUrl(base ~ "/norange", 1000, 4096, limit, tot, tag);
		auto tail = api.downloadRangeByUrl(base ~ "/f", 299_000, 4096, limit, tot, tag);
		auto beyond = api.downloadRangeByUrl(base ~ "/f", 400_000, 10, limit, tot, tag);
		int status;
		try api.downloadRangeByUrl(base ~ "/expired", 0, 10, limit, tot, tag); catch (OneDriveException e) status = e.httpStatusCode;
		int badRange;
		try api.downloadRangeByUrl(base ~ "/badrange", 1000, 100, limit, tot, tag); catch (OneDriveException e) badRange = e.httpStatusCode;
		check(ranged == content[1000 .. 5096] && ignored == content[1000 .. 5096] && tail == content[299_000 .. 300_000] && beyond.length == 0 && status == 403 && badRange == 502,
			"R10 downloadRangeByUrl: 206, 200 without Range, clamped tail, 416 past the end, 403 with the status, 206 for another range is 502");
		auto t1 = MonoTime.currTime;
		auto endless = api.downloadRangeByUrl(base ~ "/endless", 100_000, 4096, limit, tot, tag);
		auto endlessMs = (MonoTime.currTime - t1).total!"msecs";
		check(endless.length == 4096 && endlessMs < 3000, "R10 a server that ignores Range with an endless body: cut off at the requested length (" ~ to!string(endlessMs) ~ " ms)");
		t1 = MonoTime.currTime;
		bool timedOut;
		try api.downloadRangeByUrl(base ~ "/slow", 0, 1_000_000, dur!"seconds"(2), tot, tag); catch (CurlException e) timedOut = true;
		auto slowMs = (MonoTime.currTime - t1).total!"msecs";
		check(timedOut && slowMs >= 1500 && slowMs < 5000, "R10 the overall timeout ends a slow request (" ~ to!string(slowMs) ~ " ms)");
		api.releaseCurlEngine();

		// R17: shutdown during a download-URL request (counted: shutdown waits, nothing is logged later)
		{
			auto svc2 = new HydrationService(cfg, db, sync);
			svc2.rangeProbe = () => true;
			svc2.rangeUrlSource = (string driveId, string id, out long itemSize, out string itemVersion) {
				Thread.sleep(dur!"seconds"(2));
				itemSize = size;
				itemVersion = "v2";
				return "https://fake/slow-url";
			};
			svc2.rangeFetch = (string url, ulong offset, size_t length, out long total, out string etag) {
				total = size;
				return content[cast(size_t) offset .. cast(size_t) min(offset + length, content.length)].dup;
			};
			int code;
			auto reader2 = new Thread({
				try svc2.readRange("d1", "P2", "v2", size, 0, 100, 1); catch (HydrationError e) code = e.errnoCode;
			});
			reader2.start();
			Thread.sleep(dur!"msecs"(500));
			auto ts = MonoTime.currTime;
			svc2.shutdown();
			auto waited = (MonoTime.currTime - ts).total!"msecs";
			reader2.join();
			check(code == EIO && waited >= 1000, "R17 shutdown waits for a download-URL request in progress (" ~ to!string(waited) ~ " ms), the read then fails with EIO");
		}

		// R11: shutdown while a ranged request through the real fetch path is in progress
		svc.rangeFetch = null;
		svc.rangeUrlSource = (string driveId, string id, out long itemSize, out string itemVersion) {
			itemSize = 1 << 30;
			itemVersion = "slow";
			return base ~ "/slow";
		};
		int abortErrno;
		auto reader = new Thread({
			try svc.readRange("d1", "P1", "slow", 1 << 30, 0, 4096, 1); catch (HydrationError e) abortErrno = e.errnoCode;
		});
		reader.start();
		Thread.sleep(dur!"seconds"(1));
		t1 = MonoTime.currTime;
		svc.shutdown();
		reader.join();
		auto shutdownMs = (MonoTime.currTime - t1).total!"msecs";
		check(abortErrno == EIO && shutdownMs < 3000, "R11 shutdown aborts a ranged request in progress (" ~ to!string(shutdownMs) ~ " ms)");
	}

	db.closeDatabaseFile();
	writeln(failures == 0 ? "rangetest done" : "rangetest failures: " ~ to!string(failures));
}
