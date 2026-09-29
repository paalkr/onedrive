# On-demand prototype: interface contract

Working contract between the `engine` and `vfs` work streams. Local prototype, not an upstream design. Line references are against `ondemand/main` at the time of writing.

## Shape

- `sync_dir` (from config) becomes the FUSE mountpoint the user sees.
- The engine runs unchanged against a real backing directory: `runtimeSyncDirectory` is set to the backing dir when `on_demand = true`. Default backing dir: `<confdir>/ondemand/backing`, overridable with `on_demand_backing_dir`.
- Hydrated files exist in the backing dir. Online-only files do not. Directories always exist in the backing dir.
- The FUSE layer is the only writer of the backing dir while mounted. External writes to the backing dir are unsupported. The inotify monitor is not started on the backing dir in on-demand mode.
- `on_demand = true` requires `--monitor`.

## Database (engine owns)

- New column `hydration TEXT` on `item`. Values: `O` online-only, `H` hydrated, `P` pinned. NULL means hydrated (non-on-demand behaviour).
- `itemDatabaseVersion` 18 -> 19 (`itemdb.d:187`). The existing mismatch path drops and recreates the table; acceptable for the prototype (fresh test profile).
- `Item` gets a `hydration` field; insert/update/upsert/select carry it.
- The single `ItemDatabase` instance is shared. It is opened with `SQLITE_OPEN_FULLMUTEX` and `locking_mode = EXCLUSIVE` (`sqlite.d:135`, `itemdb.d:293`), and every method takes `synchronized(databaseLock)`. The FUSE layer may call select methods on that same object from its threads. It must never open a second connection.

## Engine behaviour in on-demand mode (engine owns)

- New online file (`applyPotentiallyNewLocalItem`, `sync.d:3516`): save to DB with `O`, do not queue a download. Unless the item or an ancestor is pinned (`P`), then download as today and store `P`.
- Changed online file (`applyPotentiallyChangedItem`, `sync.d:4230`): `O` stays `O`, metadata updated only. `H`/`P` re-download as today.
- Consistency check (`checkFileDatabaseItemForConsistency`, `sync.d:6608`): absent in backing dir + `O` = in sync, never queued to `databaseItemsToDeleteOnline`. Absent + `H`/`P` = deleted locally, as today.
- `isItemSynced` (`sync.d:5248`): absent + `O` = synced.
- Download failure (`sync.d:5170-5177`, `5051-5056`, `4878-4883`): never delete the DB record of an `O` item.
- Successful upload of a new local file: store `H`.
- Every other path keeps today's behaviour.

## HydrationService (engine owns, new module `src/hydration.d`)

Thread-safe. Called from FUSE worker threads. Must not touch `SyncEngine` state (its arrays are unsynchronised, `sync.d:164-220`) and must not rely on module globals in `main.d` (thread-local in D). All dependencies are passed to the constructor.

```d
enum HydrationState { onlineOnly, hydrated, pinned }

class HydrationError : Exception { int errnoCode; }   // ENETUNREACH/EIO offline, ENOENT gone online, EIO other

final class HydrationService {
	this(ApplicationConfig appConfig, ItemDatabase itemDB, string backingDir);
	HydrationState stateOf(string driveId, string id);
	// Blocks until the file is in the backing dir with a verified hash, the
	// backing mtime set from the DB, and DB state H (or P if pinned).
	// Concurrent calls for the same item wait on the one download.
	void hydrate(string driveId, string id);
	// Free up space. Only if the backing file matches the DB hash and has no
	// pending local change. Deletes the backing file, sets DB state O.
	// Returns false if refused (dirty, pinned).
	bool dehydrate(string driveId, string id);
	void pin(string driveId, string id);     // sets P, hydrates
	void unpin(string driveId, string id);   // sets H
	void shutdown();                         // cancels waiting callers with EIO
}
```

Implementation guidance: own `OneDriveApi` instance per download (as `downloadFileItem` does, `sync.d:5011-5012`), item JSON from `getPathDetailsById` (`onedrive.d:1189`), content via `downloadById` (`onedrive.d:1863`) to an absolute backing path (do not depend on process cwd). Do not call `downloadFileItem`.

## Local change events (FUSE -> engine)

The FUSE layer reports what it did to the backing dir. The engine processes events on the main thread through the existing pending-local-change path (`applyPendingLocalChanges`, `main.d:2165`), the same mapping inotify uses today.

```d
enum OnDemandChangeKind { changed, createDir, deleted, moved }
struct OnDemandLocalChange { OnDemandChangeKind kind; string path; string oldPath; }  // paths "./a/b", relative to backing dir
```

- The FUSE layer pushes into a mutex-protected queue owned by the engine (`OnDemandChangeQueue`, in `src/hydration.d`) and wakes the main loop with `send(mainTid, OnDemandWake())`. `waitForMonitorEventsInterruptibly` (`main.d:2723`) gains a receive handler for `OnDemandWake` that drains the queue into the pending local changes.
- Emit `changed` on `release()` of a handle that was written, and after `truncate`/`utimens` on a closed file. Emit `createDir` after `mkdir`, `deleted` after `unlink`/`rmdir`, `moved` after `rename` (the new path exists on disk when the event is emitted, `uploadMoveItem` requires it, `sync.d:14234-14246`).

## FUSE layer (vfs owns, new module `src/ondemand.d`, plus `src/c/fuse`, `src/fused`)

- `class OnDemandFs : Operations`, constructed with `(ItemDatabase, HydrationService, OnDemandChangeQueue, Tid mainTid, string backingDir, string rootDriveId, string rootId)`.
- Path mapping: FUSE `/a/b` -> DB `selectByPath("./a/b", rootDriveId)` (`itemdb.d:691`), backing `backingDir ~ "/a/b"`.
- `getattr`: DB item with state `O` -> size and mtime from the DB, mode `S_IFREG | 0600`. Present in the backing dir -> `lstat` of the backing file. Directories -> `S_IFDIR | 0700`. Neither -> `ENOENT`.
- `readdir`: union of DB children (`selectChildren`) and backing dir entries. Never hydrates.
- `open`: never hydrates. `O_TRUNC` on an `O` file: create an empty backing file, no download.
- `read`: if the item is `O`, `hydrate()` first (blocking), then `pread` the backing file. Map `HydrationError.errnoCode` to the FUSE error.
- `write`, `truncate` on an `O` file: hydrate first. Then operate on the backing file.
- `create`, `mkdir`, `unlink`, `rmdir`, `rename`, `utimens`: operate on the backing dir, then emit the change event.
- xattrs: `user.onedrive.pin` set to `1`/`0` -> `pin`/`unpin`. `user.onedrive.state` read-only (`online-only`, `hydrated`, `pinned`). A CLI (`--pin`, `--free`) is a later step.
- Mounting: add `fuse_new`, `fuse_mount`, `fuse_loop_mt` (3.14 signature), `fuse_exit`, `fuse_unmount`, `fuse_destroy` to the bindings, and a wrapper that runs the loop on a background thread without installing libfuse signal handlers (the client's own handler, `main.d:2421-2467`, must stay in charge). Stop: `fuse_exit` + `fuse_unmount`, then join.
- Worker threads must be registered with the D runtime (the existing per-thread attach/detach in `src/fused/fuse.d`).

## main.d wiring (engine owns)

- In the monitor branch, after the monitor initialisation (around `main.d:1290`) and before the loop (`main.d:1370`): when `on_demand`, create `HydrationService`, `OnDemandChangeQueue`, `OnDemandFs`, and start the mount.
- In `performSynchronisedExitProcess` (`main.d:2770`): stop the mount and `HydrationService.shutdown()` before `shutdownSyncEngine()` and `shutdownDatabase()`.

## Out of this iteration

Cache size limit and eviction, thumbnail pre-seeding, range reads (Nautilus reads the first 32 KB of some files; for now that hydrates them), `--pin`/`--free` CLI, shared items and SharePoint in on-demand mode, migration of an existing fully synced `sync_dir`.

## Branches

`ondemand/main` is the integration branch. `engine` works on `ondemand/engine`, `vfs` on `ondemand/vfs`, both branched from `ondemand/main`. The orchestrator merges. `engine` touches `sync.d`, `itemdb.d`, `config.d`, `main.d`, `src/hydration.d`. `vfs` touches `src/ondemand.d`, `src/c/fuse`, `src/fused`. `Makefile.in` additions: each stream adds only its own new module line.
