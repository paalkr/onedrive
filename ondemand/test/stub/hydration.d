/*
 * Test stub of the engine's src/hydration.d (see ondemand/CONTRACT.md).
 * Same public API; "downloads" copy from a local fake remote directory.
 * Not part of the onedrive build.
 *
 * The real module keeps the hydration state in the item table. This branch
 * has no hydration column yet, so the stub keeps it in memory, keyed by
 * driveId/id, and tests seed it with setStateForTest().
 */
module hydration;

import core.sync.condition;
import core.sync.mutex;
import core.thread : Thread;
import core.time : dur;
import errno = core.stdc.errno;
import std.conv : to;
import std.datetime : SysTime;
import std.file;
import std.path : buildPath, dirName;
import std.stdio : stderr;

import config;
import itemdb;

enum HydrationState { onlineOnly, hydrated, pinned }

class HydrationError : Exception
{
	int errnoCode;
	this(int errnoCode, string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
		this.errnoCode = errnoCode;
	}
}

struct OnDemandWake {}

enum OnDemandChangeKind { changed, createDir, deleted, moved }

struct OnDemandLocalChange
{
	OnDemandChangeKind kind;
	string path;
	string oldPath;
}

final class OnDemandChangeQueue
{
	private Mutex lock;
	private OnDemandLocalChange[] items;

	this()
	{
		lock = new Mutex();
	}

	void push(OnDemandLocalChange change)
	{
		lock.lock();
		scope(exit) lock.unlock();
		items ~= change;
	}

	OnDemandLocalChange[] drain()
	{
		lock.lock();
		scope(exit) lock.unlock();
		auto result = items;
		items = null;
		return result;
	}
}

final class HydrationService
{
	/* Test knobs, set before mounting */
	__gshared string fakeRemoteDir;
	__gshared uint downloadDelayMsecs;

	private ItemDatabase itemDB;
	private string backingDir;
	private Mutex lock;
	private Condition done;
	private HydrationState[string] states;
	private string[string] paths;          // key -> "a/b" relative path
	private bool[string] inFlight;
	private bool stopping;
	private uint[string] downloads;

	this(ApplicationConfig appConfig, ItemDatabase itemDB, string backingDir)
	{
		this.itemDB = itemDB;
		this.backingDir = backingDir;
		lock = new Mutex();
		done = new Condition(lock);
	}

	private static string key(string driveId, string id)
	{
		return driveId ~ "/" ~ id;
	}

	void setStateForTest(string driveId, string id, string relPath, HydrationState state)
	{
		lock.lock();
		scope(exit) lock.unlock();
		states[key(driveId, id)] = state;
		paths[key(driveId, id)] = relPath;
	}

	uint downloadCount(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		return downloads.get(key(driveId, id), 0);
	}

	HydrationState stateOf(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		return states.get(key(driveId, id), HydrationState.hydrated);
	}

	void hydrate(string driveId, string id)
	{
		auto k = key(driveId, id);
		lock.lock();
		scope(exit) lock.unlock();
		while (k in inFlight && !stopping)
			done.wait();
		if (stopping)
			throw new HydrationError(errno.EIO, "hydration service stopped");
		if (states.get(k, HydrationState.hydrated) != HydrationState.onlineOnly)
			return;
		auto rel = k in paths;
		if (rel is null)
			throw new HydrationError(errno.ENOENT, "unknown item " ~ k);

		inFlight[k] = true;
		scope(exit)
		{
			inFlight.remove(k);
			done.notifyAll();
		}
		string target = buildPath(backingDir, *rel);
		lock.unlock();
		bool relocked = false;
		scope(exit) if (!relocked) lock.lock();

		stderr.writeln("STUB download ", *rel);
		if (downloadDelayMsecs)
			Thread.sleep(dur!"msecs"(downloadDelayMsecs));
		string source = buildPath(fakeRemoteDir, *rel);
		if (!exists(source))
			throw new HydrationError(errno.ENOENT, "gone online: " ~ *rel);
		/* Download next to the backing dir, not inside it, then rename */
		string tmp = buildPath(dirName(backingDir), "hydrate-tmp-" ~ id);
		copy(source, tmp);
		Item item;
		if (itemDB.selectById(driveId, id, item))
			setTimes(tmp, item.mtime, item.mtime);
		rename(tmp, target);

		lock.lock();
		relocked = true;
		downloads[k] = downloads.get(k, 0) + 1;
		states[k] = HydrationState.hydrated;
	}

	bool dehydrate(string driveId, string id)
	{
		auto k = key(driveId, id);
		lock.lock();
		scope(exit) lock.unlock();
		if (states.get(k, HydrationState.hydrated) != HydrationState.hydrated || k !in paths)
			return false;
		string target = buildPath(backingDir, paths[k]);
		if (exists(target))
			remove(target);
		states[k] = HydrationState.onlineOnly;
		return true;
	}

	void pin(string driveId, string id)
	{
		hydrate(driveId, id);
		lock.lock();
		scope(exit) lock.unlock();
		states[key(driveId, id)] = HydrationState.pinned;
	}

	void unpin(string driveId, string id)
	{
		lock.lock();
		scope(exit) lock.unlock();
		auto k = key(driveId, id);
		if (states.get(k, HydrationState.hydrated) == HydrationState.pinned)
			states[k] = HydrationState.hydrated;
	}

	void shutdown()
	{
		lock.lock();
		scope(exit) lock.unlock();
		stopping = true;
		done.notifyAll();
	}
}
