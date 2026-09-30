// What is this module called?
module thumbnails;

// What does this module require to function?
import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.algorithm;
import std.conv;
import std.datetime;
import std.file;
import std.json;
import std.net.curl : HTTP, CurlException;
import std.path;
import std.process;
import std.string;
import std.uni : toLower;

// What other modules that we have created do we need to import?
import config;
import itemdb;
import log;
import onedrive;
import thumbnailpng;
import util;

// Writes freedesktop thumbnails for online-only files from Microsoft Graph thumbnails, so a file
// manager never reads (and so hydrates) an online-only file to draw its thumbnail.
// Runs on its own thread after each sync cycle, rate-limited. It never reads files in the mount.
final class ThumbnailService {
	private ApplicationConfig appConfig;
	private ItemDatabase itemDB;
	private string mountPoint;
	private string converter;
	private string cacheRoot;
	private long connectTimeout;
	private long dataTimeout;

	private Mutex serviceMutex;
	private Condition serviceCondition;
	private Thread worker;
	private bool passRequested;
	// Items to handle before the next full pass (new online-only files), in arrival order
	private Item[] priorityItems;
	private enum priorityItemsLimit = 10_000;
	private bool shuttingDown;
	private bool workerRunning;
	private shared bool abortTransfers;
	// Items already attempted, by driveId/id -> eTag, so an item without a thumbnail is not retried until it changes
	private string[string] attempted;

	// Pause between thumbnail fetches, and the most fetches per pass
	private enum fetchInterval = dur!"msecs"(250);
	private enum maxFetchesPerPass = 200;
	// freedesktop thumbnail directories and their sizes
	private enum string[2] sizeDirectories = ["normal", "large"];
	private enum int[2] sizePixels = [128, 256];

	// Returns null when no PNG converter is installed
	static ThumbnailService create(ApplicationConfig appConfig, ItemDatabase itemDB, string mountPoint) {
		string converter = findConverter();
		if (converter.empty) {
			addLogEntry("On-demand: thumbnails are disabled because gdk-pixbuf-thumbnailer is not installed");
			return null;
		}
		return new ThumbnailService(appConfig, itemDB, mountPoint, converter);
	}

	private this(ApplicationConfig appConfig, ItemDatabase itemDB, string mountPoint, string converter) {
		this.appConfig = appConfig;
		this.itemDB = itemDB;
		this.mountPoint = buildNormalizedPath(absolutePath(mountPoint));
		this.converter = converter;
		string cacheHome = environment.get("XDG_CACHE_HOME", "");
		if (cacheHome.empty || !isAbsolute(cacheHome)) cacheHome = buildPath(environment.get("HOME", "/"), ".cache");
		this.cacheRoot = buildPath(cacheHome, "thumbnails");
		// Read configuration once; appConfig is owned by the main thread
		this.connectTimeout = appConfig.getValueLong("connect_timeout");
		this.dataTimeout = appConfig.getValueLong("data_timeout");
		serviceMutex = new Mutex();
		serviceCondition = new Condition(serviceMutex);
	}

	// Ask for a thumbnail pass; called by the main thread after a sync cycle. Never blocks.
	void requestPass() {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		if (shuttingDown) return;
		passRequested = true;
		startWorkerLocked();
		serviceCondition.notifyAll();
	}

	// Handle these items (just recorded as online-only) soon, ahead of a full pass. Never blocks.
	void requestItems(Item[] items) {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		if (shuttingDown) return;
		foreach (item; items) {
			if (!isThumbnailable(item.name)) continue;
			if (priorityItems.length >= priorityItemsLimit) break;
			priorityItems ~= item;
		}
		startWorkerLocked();
		serviceCondition.notifyAll();
	}

	private void startWorkerLocked() {
		if (worker is null) {
			workerRunning = true;
			worker = new Thread(&workerLoop);
			worker.isDaemon = true;
			worker.start();
		}
	}

	// Stop the worker; waits (bounded) so it does not use the database after shutdown
	void shutdown() {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		shuttingDown = true;
		atomicStore(abortTransfers, true);
		serviceCondition.notifyAll();
		MonoTime deadline = MonoTime.currTime + dur!"seconds"(30);
		while (workerRunning && (MonoTime.currTime < deadline)) {
			serviceCondition.wait(dur!"msecs"(200));
		}
		if (workerRunning) addLogEntry("WARNING: On-demand: the thumbnail worker did not stop within 30 seconds");
	}

	private bool isShuttingDown() {
		serviceMutex.lock();
		scope(exit) serviceMutex.unlock();
		return shuttingDown;
	}

	private void workerLoop() {
		scope(exit) {
			serviceMutex.lock();
			workerRunning = false;
			serviceCondition.notifyAll();
			serviceMutex.unlock();
		}
		while (true) {
			serviceMutex.lock();
			while (!passRequested && (priorityItems.length == 0) && !shuttingDown) serviceCondition.wait();
			if (shuttingDown) {
				serviceMutex.unlock();
				return;
			}
			Item[] items = priorityItems;
			priorityItems = null;
			bool fullPass = passRequested && (items.length == 0);
			if (fullPass) passRequested = false;
			serviceMutex.unlock();
			try {
				// New items first; a requested full pass follows once they are done
				runPass(fullPass ? itemDB.selectOnlineOnlyFiles() : items);
			} catch (Exception e) {
				addLogEntry("On-demand: thumbnail pass failed: " ~ e.msg);
			}
		}
	}

	private void runPass(Item[] candidates) {
		OneDriveApi api;
		scope(exit) {
			if (api !is null) {
				api.releaseCurlEngine();
				api = null;
			}
		}
		int fetches = 0;
		int written = 0;
		foreach (candidate; candidates) {
			if (isShuttingDown() || (fetches >= maxFetchesPerPass)) break;
			if (!isThumbnailable(candidate.name)) continue;
			// Use the current record: the item may have been hydrated, moved or removed meanwhile
			Item item;
			if (!itemDB.selectById(candidate.driveId, candidate.id, item) || (item.hydration != "O") || (item.type != ItemType.file)) continue;
			string key = item.driveId ~ "/" ~ item.id;
			if (auto previousETag = key in attempted) {
				if (*previousETag == item.eTag) continue;
			}

			string mountPath = buildNormalizedPath(buildPath(mountPoint, itemDB.computePath(item.driveId, item.id)));
			string uri = fileUriForPath(mountPath);
			string mtime = to!string(item.mtime.toUnixTime());
			if (thumbnailsValid(uri, mtime)) {
				attempted[key] = item.eTag;
				continue;
			}

			if (api is null) {
				api = new OneDriveApi(appConfig);
				api.initialise();
				api.setTransferAbortFlag(&abortTransfers);
			}
			fetches++;
			ThumbnailOutcome outcome = writeThumbnails(api, item, uri, mtime);
			if (outcome == ThumbnailOutcome.written) written++;
			// Retry transient failures on a later pass; do not retry an unchanged item without a thumbnail
			if (outcome != ThumbnailOutcome.retryLater) attempted[key] = item.eTag;
			Thread.sleep(fetchInterval);
		}
		if (written > 0) addLogEntry("On-demand: wrote thumbnails for " ~ to!string(written) ~ " online-only file(s)");
	}

	// Both sizes exist and describe this URI and mtime
	private bool thumbnailsValid(string uri, string mtime) {
		string name = thumbnailFileName(uri);
		foreach (directory; sizeDirectories) {
			string path = buildPath(cacheRoot, directory, name);
			if (!exists(path)) return false;
			try {
				PngChunk[] chunks;
				if (!parsePngChunks(cast(ubyte[]) read(path), chunks)) return false;
				if ((pngTextValue(chunks, "Thumb::URI") != uri) || (pngTextValue(chunks, "Thumb::MTime") != mtime)) return false;
			} catch (Exception e) {
				return false;
			}
		}
		return true;
	}

	private enum ThumbnailOutcome { written, none, retryLater }

	private ThumbnailOutcome writeThumbnails(OneDriveApi api, Item item, string uri, string mtime) {
		JSONValue response;
		try {
			response = api.getThumbnailsById(item.driveId, item.id);
		} catch (OneDriveException e) {
			if (debugLogging) {addLogEntry("On-demand: no thumbnails for " ~ item.name ~ ": " ~ e.msg, ["debug"]);}
			return (e.httpStatusCode == 404) ? ThumbnailOutcome.none : ThumbnailOutcome.retryLater;
		}
		string sourceUrl = thumbnailSourceUrl(response);
		if (sourceUrl.empty) {
			if (debugLogging) {addLogEntry("On-demand: Microsoft OneDrive has no thumbnail for " ~ item.name, ["debug"]);}
			return ThumbnailOutcome.none;
		}

		string name = thumbnailFileName(uri);
		string workDir = buildPath(cacheRoot, ".onedrive-ondemand");
		string sourcePath = buildPath(workDir, name ~ ".source");
		scope(exit) removeQuietly(sourcePath);
		try {
			ensureDirectory(workDir);
			if (!downloadUrl(sourceUrl, sourcePath)) return ThumbnailOutcome.retryLater;
			foreach (index, directory; sizeDirectories) {
				string targetDir = buildPath(cacheRoot, directory);
				ensureDirectory(targetDir);
				string convertedPath = buildPath(workDir, name ~ "." ~ directory ~ ".png");
				scope(exit) removeQuietly(convertedPath);
				auto result = execute([converter, "-s", to!string(sizePixels[index]), sourcePath, convertedPath]);
				if ((result.status != 0) || !exists(convertedPath)) {
					if (debugLogging) {addLogEntry("On-demand: thumbnail conversion failed for " ~ item.name ~ ": " ~ strip(result.output), ["debug"]);}
					return ThumbnailOutcome.none;
				}
				string[string] text = ["Thumb::URI": uri, "Thumb::MTime": mtime];
				if (!item.size.empty) text["Thumb::Size"] = item.size;
				ubyte[] png = withThumbnailTextChunks(cast(ubyte[]) read(convertedPath), text);
				if (png is null) return ThumbnailOutcome.none;
				// Write atomically so a file manager never reads a partial thumbnail
				string targetPath = buildPath(targetDir, name);
				string temporaryPath = targetPath ~ ".onedrive-tmp";
				std.file.write(temporaryPath, png);
				temporaryPath.setAttributes(octal!600);
				rename(temporaryPath, targetPath);
			}
		} catch (Exception e) {
			addLogEntry("On-demand: unable to write thumbnails for " ~ item.name ~ ": " ~ e.msg);
			return ThumbnailOutcome.retryLater;
		}
		return ThumbnailOutcome.written;
	}

	// URL of the largest standard thumbnail of the first thumbnail set
	private static string thumbnailSourceUrl(JSONValue response) {
		if ((response.type != JSONType.object) || !("value" in response) || (response["value"].type != JSONType.array)) return null;
		if (response["value"].array.length == 0) return null;
		JSONValue set = response["value"].array[0];
		if (set.type != JSONType.object) return null;
		foreach (size; ["large", "medium", "small"]) {
			if ((size in set) && (set[size].type == JSONType.object) && ("url" in set[size]) && (set[size]["url"].type == JSONType.string)) {
				return set[size]["url"].str;
			}
		}
		return null;
	}

	// Thumbnail URLs returned by Microsoft Graph are pre-authenticated
	private bool downloadUrl(string url, string path) {
		HTTP http = HTTP(url);
		http.connectTimeout = dur!"seconds"(connectTimeout);
		http.dataTimeout = dur!"seconds"(dataTimeout);
		http.maxRedirects = 5;
		ubyte[] content;
		http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
		http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow) {
			return atomicLoad(abortTransfers) ? 1 : 0;
		};
		try {
			http.perform();
		} catch (CurlException e) {
			if (debugLogging) {addLogEntry("On-demand: thumbnail download failed: " ~ e.msg, ["debug"]);}
			return false;
		}
		if ((http.statusLine.code != 200) || (content.length == 0)) return false;
		std.file.write(path, content);
		return true;
	}

	private static bool isThumbnailable(string name) {
		static immutable string[] extensions = [
			".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic", ".heif", ".tif", ".tiff",
			".pdf",
			".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".wmv", ".3gp",
			".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp", ".rtf"
		];
		return canFind(extensions, toLower(extension(name)));
	}

	private static string findConverter() {
		foreach (directory; environment.get("PATH", "/usr/bin:/bin").split(":")) {
			if (directory.empty) continue;
			string candidate = buildPath(directory, "gdk-pixbuf-thumbnailer");
			if (exists(candidate) && isFile(candidate)) return candidate;
		}
		return null;
	}

	private static void ensureDirectory(string path) {
		if (!exists(path)) {
			mkdirRecurse(path);
			path.setAttributes(octal!700);
		}
	}

	private static void removeQuietly(string path) {
		try {
			if (exists(path)) std.file.remove(path);
		} catch (Exception e) {
			// Leftover work files are harmless
		}
	}
}
