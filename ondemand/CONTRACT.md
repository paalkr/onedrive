# On-demand prototype: interface contract

Working contract between the `engine` and `vfs` work streams. Local prototype, not an upstream design. Line references are against `ondemand/main` at the time of writing.

## Shape

- `sync_dir` (from config) becomes the FUSE mountpoint the user sees.
- **Layout (iteration 5, see "Physical sync_dir layout" below):** the physical `sync_dir` holds the hydrated files, with the FUSE mount on top of it. "Backing dir" in this document means that physical directory under the mount. It is reached as `/proc/self/fd/<n>`, a directory descriptor opened before the mount.
  - The engine runs unchanged against it. `runtimeSyncDirectory` is `sync_dir`, and the working directory is set to it before the mount, so all relative `./` paths stay on the physical tree.
  - The previous layout used a separate backing directory (`<confdir>/ondemand/backing`, or the now deprecated `on_demand_backing_dir`). Its content is migrated once.
- Hydrated files exist in the backing dir. Online-only files do not. Directories always exist in the backing dir. When the client is stopped (unmounted), hydrated files and all folders are directly visible in `sync_dir`.
- While mounted, the FUSE layer is the only writer of the backing dir. External writes to the backing dir are unsupported. The inotify monitor is not started in on-demand mode; local changes come from the FUSE change queue.
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

## Iteration 4: D-Bus status interface (engine owns the service, gui consumes it)

Purpose: give file managers, tray icons and GUIs (the OneDriveGUI fork) a supported way to read sync status, transfers and issues, instead of parsing log output. Session bus only. Works in normal and on-demand mode; on-demand specifics are capability-gated. Off by default upstream-style is not required for the prototype, but the service must never block or slow the sync engine: all D-Bus work runs on its own thread, reading snapshots the engine publishes.

### Naming
- Bus name per running client instance: `io.github.abraunegg.OneDrive.i<hex>` where `<hex>` is the first 16 hex chars of sha256(absolute confdir path). Clients discover instances by listing names with that prefix.
- Object path: `/io/github/abraunegg/OneDrive`.
- Interface: `io.github.abraunegg.OneDrive1` (version 1; incompatible changes get a new interface name).

### Properties (read-only, org.freedesktop.DBus.Properties, with PropertiesChanged)
- `Version` (s): client version string.
- `ConfigDir` (s): absolute confdir. `SyncDir` (s): what the user sees (the mount in on-demand mode). `Account` (s): account email/UPN if known. `AccountType` (s): `personal` | `business` | `sharepoint` | `unknown`.
- `OnDemand` (b). `Capabilities` (as): subset of `ondemand`, `actions`, `issues`, `transfers`, `pause`.
- `State` (s): `starting` | `idle` | `syncing` | `paused` | `offline` | `error` | `stopping`.
- `StateDetail` (s): one human sentence for tooltips (e.g. "Uploading 3 files", "Waiting for network").
- `LastSyncTime` (x): unix seconds of the last completed sync cycle, 0 if none.
- `QuotaUsed`, `QuotaTotal` (t): bytes, 0 if unknown.
- `PendingUploads`, `PendingDownloads` (u).

### Methods
- `GetTransfers() -> a(ssstt)`: (path relative to SyncDir, direction `upload`|`download`|`hydrate`, state `queued`|`active`, bytesDone, bytesTotal).
- `GetIssues() -> a(sssssx)`: (issueId, path, kind, severity, message, unixTime). severity `info` (handled automatically) or `attention` (needs the user). kinds: `conflict_copy` (info; path = the copy, message names the original), `locked_online` (info while retrying), `deferred_online_change` (info), `upload_failed`, `download_failed`, `invalid_name`, `too_large`, `permission_denied`, `quota_exceeded`, `other` (attention). Bounded list (most recent 500), kept in memory; conflict copies also recovered at startup by scanning the DB for safeBackup names is optional.
- `DismissIssue(s issueId)`.
- `SyncNow()`: request an immediate sync cycle (wake the monitor loop).
- `Pause(u minutes)` / `Resume()`: only if `pause` in Capabilities; pause stops starting new transfers and sync cycles, finishes in-flight ones, State becomes `paused`; minutes 0 = until Resume or restart.

### Signals
- `IssuesChanged()`, `TransfersChanged()` (rate-limited, at most 2/s), plus PropertiesChanged for State/StateDetail/counters.

### File-level actions
Stay on the existing xattr interface (`user.onedrive.action`, `user.onedrive.state`, `user.onedrive.weburl`); not duplicated on D-Bus.

## Iteration 4: GUI (gui owns, OneDriveGUI fork paalkr/OneDriveGUI)

- Every new feature is capability-gated: when the profile's client exposes the D-Bus interface, use it; otherwise OneDriveGUI behaves exactly as upstream.
- When a D-Bus instance for a profile's confdir is already running (e.g. our systemd user unit), the GUI attaches to it and does NOT spawn its own client process for that profile.
- Tray icon states like the Windows client: synced, syncing, paused, offline, error/attention; tooltip from StateDetail; menu: open folder, view online, pause/resume (if capability), sync now, settings, quit GUI (does not stop a systemd-managed client).
- Status window per profile: current transfers with progress; an Issues view split into "Handled automatically" (info) and "Needs attention" (attention) with actions: open folder, open file, view online (via xattr weburl in on-demand mode), dismiss.
- Profile setup: option "Files On-Demand" that writes a profile usable by `onedrive-ondemand@<profile>.service` and offers to enable that unit instead of GUI-managed process start.
- Folder selection (sync_list) and settings use OneDriveGUI's existing editors.

## Iteration 5: physical sync_dir layout (engine, with the FUSE side)

Hydrated files live in the physical `sync_dir`, with the FUSE mount on top of it (upstream ADR-001 §11). There is no separate backing directory.

### Startup order (main.d)
1. **Option checks.**
2. **`prepareOnDemandPhysicalSyncDir()`:**
   - **Stale mount:** `sync_dir` is resolved with `realpath()` (the parent only, when the last component is a dead mount) and compared with the `fuse.onedrive` entries of `/proc/self/mounts`. An on-demand mount on it is probed with `statfs` in a child process with a timeout. If it answers, another client is running and the start is refused. If it times out, a hung client holds it and the start is refused. If it fails (dead, ENOTCONN), it is unmounted with `fusermount3 -u -z` (refused if that fails). If `timeout` or `fusermount3` cannot be run, the start is refused. The client never changes into a dead mount.
   - **Relocation:** if the database marker `<db>.ondemand` records another directory (the previous layout's backing dir, or the previous `sync_dir` after a change), that directory is moved to `sync_dir` with one `rename()`. That needs the same filesystem and an absent or empty `sync_dir`; otherwise the start is refused with a message. No copying and no overwriting, the database is not changed, and nothing is uploaded or deleted. Without a marker, a non-empty `<confdir>/ondemand/backing` is migrated the same way.
   - **After the move:** the marker is rewritten to `sync_dir`, and the previous layout's `.<backing>.staging` is removed.
   - **Intent record:** before the `rename()`, `<confdir>/.ondemand-move-intent` is written with the source and target paths; it is removed after the marker is rewritten.
   - **Interrupted move:** completed (marker rewritten, no `--resync`) only when the intent record names this move: its target is `sync_dir`, its source is gone and `sync_dir` has content.
   - **Recorded directory gone without that proof** (the user deleted the backing dir, or `sync_dir` points at another existing folder): the start is refused with a message pointing at `--resync`. The files in `sync_dir` are never adopted as the tree the database describes.
   - **`--dry-run`:** nothing is moved or unmounted; when a move, a completion or an unmount would be needed, the start is refused with a message.
3. **Database check** (`checkOnDemandProfileState`, unchanged): the marker must record `sync_dir`, or the database must be empty.
4. **`chdir(sync_dir)`, then `open(".", O_DIRECTORY)`:** `appConfig.onDemandPhysicalRoot` becomes `/proc/self/fd/<n>`, before the mount.
5. **Missing content check** (`onDemandRecordedLocalFilesAllMissing`, next to `check_nomount`): when the database records more than 5 hydrated or pinned files and not one of them is present, the start is refused (an unmounted disk, or `sync_dir` emptied while stopped). `--resync` makes them online-only without deleting anything online.
6. **The mount** on top of `sync_dir` (`startOnDemandMount(..., backingDir = onDemandPhysicalRoot, ...)`), **then the first sync cycle** in the monitor loop. The first consistency check and local scan therefore run with the mount in place, on the physical tree through the working directory.

### Rules
- **Engine paths:** the engine uses paths relative to its working directory, which stays on the physical directory after the mount. An absolute path built from `sync_dir` resolves through the mount and must not be used for file access. The places that did are fixed:
  - `pathIsProtectedByNoSync`
  - the relative-symlink check (restores the working directory with `fchdir`)
  - the recycle bin move
  - `getPathOwnerMismatch`
  - `configuredBusinessSharedFilesDirectoryName` (relative in on-demand mode)
- **FUSE threads and HydrationService:** they use `/proc/self/fd/<n>/...`. The root is `/proc/self/fd/<n>/` with a trailing slash, because `lstat` of the bare magic link reports the link itself.
- **Staging:** hydrations stage in `<sync_dir>/.onedrive-ondemand:staging` (`onDemandStagingDirName`), so the final rename stays on one filesystem. OneDrive and SharePoint do not allow `:` in names, so no online item can collide with it.
  - The FUSE layer hides it: ENOENT in getattr, not listed, and create/mkdir/rename to it give EACCES.
  - The engine's local scan never enters it (`isOnDemandStagingPath`).
  - A download left there by a crash is removed when HydrationService starts. The item keeps state O, because the state is only set after the rename into place.
- **`sync_dir` change:** this moves the physical directory (same filesystem). Otherwise `--resync` is required, as before.
- **Offline changes:** with the client stopped, hydrated files are ordinary files. The first sync cycle after the start handles them as in normal mode:
  - a changed file is uploaded (consistency check);
  - a new file is uploaded (local scan);
  - a deleted hydrated file (H or P, absent) is a real delete;
  - a rename is a delete plus a new file.

  Online-only items (O, absent) stay in sync (§13 invariant).
- **Big deletes:** the online deletes one consistency pass queues are totalled (a folder counts with its database children). When the total reaches `classify_as_big_delete`, none of them is sent and the client exits, as for a big delete in normal mode (`--force` overrides). The per-item check alone never trips, because an emptied `sync_dir` deletes its files one by one.
- **Content created through the mount over an online-only item** (O_TRUNC or truncate to 0 via `createEmpty`, or a file saved by rename over it via `noteLocalContent(driveId, id)`) makes the item H at once, in the same state-lock section. If the client stops before the upload, the next start sees a modified hydrated file and uploads it under its own name, with the usual content-based conflict check. `noteLocalContent` is called by the FUSE rename when a file that is not a database item replaces an online-only item.
- **A file put over an online-only item while stopped** (its inode changed before the engine started, and the item is still O) never overwrites the online version. With the online content (hash) it becomes H. Otherwise it is renamed to a conflict copy (`safeBackup`), which is uploaded as a new file.
- **Open handles:** the open-handle count (`noteOpen`/`noteClose`, free refused while open, deferred online changes) only sees opens through the mount. A handle on the physical file opened before the mount, or while the client was stopped, is not counted: the engine can replace or free such a file while that handle is open.
- **On-access scanners and free:** `noteOpen(driveId, id, onAccessScanner)` / `noteClose(driveId, id, onAccessScanner)` (the flag defaults to false). The FUSE layer sets it when the opener's thread comm, process comm or executable is in `onAccessScannerNames` (ondemand.d, next to the thumbnailer list; CrowdStrike reads FUSE files as `falcon-fuse`). A user "free up space" (xattr action, `--free`, the file manager, and each file of a folder free) refused only because the file is open waits while every open handle is a scanner's, polling every 100 ms for up to `onDemandScannerWaitMsecs` (5 s), then frees or returns EBUSY. Any other open handle refuses at once. The wait happens in the requesting thread (a FUSE thread for the xattr, the action worker for folders) and holds no lock while sleeping.
- **`on_demand_backing_dir`:** deprecated. It is only read as the source of the one-time migration, with a warning.

## Iteration 6: no download without a deliberate user action (ranged reads)

Decided by Pål: a file is only downloaded by a deliberate user action (opening it in an application, Properties, a copy or move, the OneDrive actions). Browsing in a file manager sniffs content types and reads previews; that must not download. The caller cannot tell a sniff from a copy (Nautilus reads both on its `pool-org.gnome.` worker threads), so the read volume decides.

### Background readers (ondemand.d)
- **Classification at open**, for database files: the opener is a background reader when its process comm or executable is in `backgroundReaderNames` (next to the thumbnailer list: nautilus, nemo, caja, thunar, dolphin, pcmanfm, gvfsd*, tracker-*, localsearch*, baloo*, zeitgeist*; `*` is a prefix), or when it is an on-access scanner (`onAccessScannerNames`). The thread comm is not used for this, because file managers read on generic worker threads. Thumbnailers are never background readers; they stay refused.
- **read() of an online-only file** on a background handle is answered with `HydrationService.readRange()`, without a local file and without a state change. The handle counts the bytes served.
- **Escalation:** when a handle would read more than `rangedReadLimit` (1 MiB) in total (a copy or move), the item is hydrated normally and the rest is served from the local file. A file at or under 1 MiB read by a background reader stays online-only (accepted).
- **Unchanged:** writes, truncate, rename, xattr actions, and reads by every other process (they hydrate on the first read, as before).
- **Offline:** the read fails with EIO at once.
- **Log:** `On-demand: served N bytes of <path> to <caller> without downloading` at release (at most once a minute per path), and `On-demand: downloading <path> because <caller> read more than 1 MiB` on escalation. `<caller>` is the caller identity of the hydration log.

### HydrationService.readRange(driveId, id, offset, length)
- Returns the bytes from the cache or Graph; fewer at the end of the file, none past it. Throws HydrationError: EIO (offline or any failed request), ENOENT (gone online).
- **Graph:** the item's `@microsoft.graph.downloadUrl` from a plain item GET (`OneDriveApi.getDownloadUrlById`, after `probeMicrosoftService`), then `OneDriveApi.downloadRangeByUrl(url, offset, length)`: one GET with `Range: bytes=a-b`, no Authorization header, no retry loop. 206 is used as is; 200 (Range ignored) is sliced; 416 means past the end; any other status throws OneDriveException. A malware-flagged item is refused.
- **Cache:** 128 KiB blocks per item (one request covers the kernel's read-ahead; a run of missing blocks is one request). Items are dropped 60 s after their last read; all items together are capped at 64 MiB (least recently read first). A new size at a URL refresh drops the item's blocks.
- **URL:** reused for 30 minutes. A 401, 403 or 410 fetches a new URL once and retries.
- **Offline:** a network failure (curl error, or the probe fails) logs once per item and makes every ranged read fail with EIO for 15 s without a request. The first failing read is bounded by the configured `dns_timeout`/`connect_timeout` of the probe (it fails at once when there is no network at all).
- **Locks:** only the range cache's mutex and a per-item fetch lock (concurrent readers of an item wait for one request and share its blocks). Never the state lock, the transaction lock or the database lock across network I/O.
- **Test hooks:** `rangeUrlSource` and `rangeFetch` replace Graph (test-physical rangetest).

### Assumptions about Graph (not verified against a real account)
- A plain `GET /drives/{d}/items/{i}` returns `@microsoft.graph.downloadUrl` for files, on Personal and Business.
- That URL accepts `Range` and answers 206, and expires after about an hour (401/403/410 afterwards).
- If a server ignored Range, the full body would be fetched for each block request (correct, but slow); this is handled, not optimised.
