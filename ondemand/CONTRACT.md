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

## Iteration 2: actions, CLI, thumbnails, file manager

### Action interface (vfs owns the FUSE side, engine owns HydrationService)

One interface for every client (CLI, Nautilus extension, scripts): extended attributes on paths inside the mount. Nothing outside the running client opens the database.

- `user.onedrive.state` (read): `online-only`, `hydrated`, `pinned`. For a directory: `pinned` if the directory is pinned, otherwise `hydrated` if every file below it is hydrated or pinned, otherwise `online-only`. Items not in the DB (new, not yet uploaded): `local`.
- `user.onedrive.action` (write-only, value is the action):
  - `download`: hydrate now, state becomes H. Directory: every O file below it.
  - `pin` ("always keep on this device"): state P, hydrate. Directory: the directory and everything below it, and new online files below it later.
  - `unpin`: P -> H (directory: recursive), no dehydration. Absent pinned files become O (engine rule from 516c3f9).
  - `free` ("free up space"): dehydrate. Files: refused (EBUSY) if pinned, if there is a pending local change, or if the backing file does not match the DB hash; state O. Directory: unpin recursively first, then dehydrate every file below it; files that are refused stay local and are reported in the log. Returns success if the call was accepted.
  - Directory actions run on a background worker in HydrationService, not in the FUSE request thread; the setxattr returns once the work is queued. Progress and per-file failures go to the client log.
- `user.onedrive.pin` stays as a compatibility alias (`1` = pin, `0` = unpin).
- `st_blocks` is 0 for online-only files so `du` shows real local usage.

### CLI (engine owns)

`onedrive --confdir <dir> --download <path>`, `--pin <path>`, `--unpin <path>`, `--free <path>`, `--status <path>`: path inside the mount (absolute, or relative to cwd). Implemented purely as setxattr/getxattr on the mount path, so it works while the monitor process is running and needs no database access. Errors: not inside an on-demand mount, mount not active.

### Thumbnails (engine owns)

Goal: the file manager never needs to read an online-only file to draw a thumbnail.
- After each sync cycle, for O files of thumbnailable types (images, pdf, video, office documents) with no valid cached thumbnail, fetch Graph thumbnails for the item and write freedesktop thumbnails (https://specifications.freedesktop.org/thumbnail-spec/latest/) to `~/.cache/thumbnails/{normal,large}/<md5(uri)>.png` with `Thumb::URI` = the file's URI inside the MOUNT and `Thumb::MTime` = the mtime the mount reports for that file. Verified by spike: Nautilus 46 then uses the cached thumbnail and runs no thumbnailer.
- PNG output is required. Convert with an installed tool (e.g. `gdk-pixbuf-thumbnailer`) or in D; inject the tEXt chunks in D. If no converter is available, skip thumbnails with one log line.
- Config `on_demand_thumbnails` (bool, default true). Rate-limited, runs off the main sync path, never hydrates.

### File manager (nautilus owns, new `contrib/nautilus/onedrive-ondemand.py`)

nautilus-python 4.0 extension for Nautilus 46: shows the state per file and adds a context-menu submenu "OneDrive" with "Download now", "Always keep on this device" / "Stop keeping on this device", "Free up space", for files AND folders, only for paths inside an on-demand mount, all via the action xattrs above. State indication: emblems if Nautilus 46 still renders them, otherwise the best supported alternative (to be verified, not assumed).

## Iteration 3: behaviour close to the Windows client

Goal: the Linux experience matches the Windows OneDrive client as closely as the platform allows. Conflict copies keep upstream's naming (`<name>-<host>-safeBackup-NNNN.<ext>`).

### Open locally while changed online (engine owns, vfs supplies open counts)

- When the engine is about to replace a present backing file with a newer online version (changed online, H or P item) and HydrationService reports open handles for that item (`noteOpen` count > 0), it does not replace the file. It records the item as "online change deferred" and logs one line.
- On the last `noteClose` of such an item, the engine re-evaluates it on the main thread (wake via the existing OnDemandWake/queue path): if the backing file is unchanged against the DB, download and replace as normal; if it changed locally, apply the normal conflict handling (safeBackup of the local version, then download), exactly once.
- A deferred item that stays open is re-checked at every sync cycle; nothing is lost if the process restarts (the next sync sees the online change again).

### Locked online (engine owns)

- An upload refused because the item is checked out or locked for editing (HTTP 423, "resourceLocked" / the existing "checked out or locked for editing by another user" path) is retried on a short schedule instead of waiting for the next sync cycle: 30 s, 60 s, 120 s, then every monitor interval. Other failures keep today's behaviour.
- The item shows state `pending` (see below) while it waits.

### Transient sync states (engine owns the source, vfs exposes, nautilus shows)

`user.onedrive.state` gains three values, which take precedence over the stored hydration state while they apply:
- `syncing`: an upload or download (including hydration) of this item is in progress.
- `pending`: a local change is queued or waiting for a retry (locked online, deferred online change, offline).
- `error`: the last upload/download of this item failed with a non-transient error; cleared on the next success or when the item changes.
The engine keeps these in a thread-safe per-item map (driveId, id) exposed through `HydrationService.transientStateOf(driveId, id)`; items not in the map report the stored state as before. Directories: `syncing` if any file below is syncing, else `pending` if any is pending, else `error` if any is error, else as before (use the existing 2 s directory cache, invalidated on transient changes too).

### View online (engine + vfs + nautilus)

- `user.onedrive.weburl` (read): the item's OneDrive web URL (Graph `webUrl`). The engine fetches it on demand with `getPathDetailsById` (never hydrates, 10 s timeout, cached per eTag). ENODATA for items not in the DB; EIO if offline.
- Nautilus: "View online" in the OneDrive submenu for a single selected file or folder; opens the URL with the default browser (Gio.AppInfo.launch_default_for_uri), asynchronously.

### Emblems (nautilus owns)

online-only: cloud; hydrated: check; pinned: circled check; syncing and pending: sync arrows; error: an error emblem (e.g. `emblem-important` / `dialog-error-symbolic`, whichever exists in the theme); local (not yet in the DB): sync arrows. Poll interval unchanged; items in `syncing`/`pending` are refreshed every 2 s until they settle.
