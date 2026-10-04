# Files On-Demand in this fork: what we learned, and the path to ADR-001

Status: this fork is an experimental implementation of Files On-Demand for the Linux client. We built it to learn what on-demand needs on Linux in practice. It is used every day on a personal OneDrive drive. The aim is to converge on ADR-001 ("FUSE Overlay, Authoritative Namespace and Local Storage"), not to propose a different architecture. Where the fork departs from the ADR, this document says so, explains why it was built that way, and describes the step back to the ADR model.

The document records what was built, what held up in use, and which pieces could be offered upstream on their own. Section references such as "ADR §11" point to ADR-001.

The fork started from `implement-on-demand-capability` at f692e54 (2026-09-10). Most of the code is in new modules, mainly `src/ondemand.d` (the FUSE filesystem) and `src/hydration.d` (hydration, ranged reads, actions). The changes to `src/sync.d`, `src/main.d`, `src/itemdb.d` and `src/config.d` are gated on `on_demand`, except the CurlEngine fix (§16) and the D-Bus service (§15). Two working documents sit next to this one: `ondemand/CONTRACT.md` (the interface between the engine side and the FUSE side, built up in iterations) and `ondemand/OPTIONS.md` (every config option classified for on-demand mode).

## 1. Summary

- Agreed with the ADR and built that way:
  - the item database is the namespace authority;
  - hydration state is a database column;
  - hydrated files live in the physical `sync_dir` under the FUSE mount;
  - cloud-only absence is never read as a deletion;
  - the engine keeps ownership of Graph, uploads, downloads and conflicts.
- The physical layout of ADR §11 replaced our first design, a separate backing directory. Existing installs migrate automatically. It now runs on the author's whole drive.
- Three things differ from the ADR today. For each, §7 to §9 give the reason, the benefit, what following the ADR would take, and our willingness to follow it:
  1. Local changes reach the engine from the FUSE layer instead of inotify (§7).
  2. "Always keep on this device" is a hydration state, not an `always_local` policy (§8).
  3. `on_demand` requires `--monitor` (§9).
- Some pieces stand on their own and do not depend on those three: FUSE3 portability, hydration concurrency, safe dehydration, open-handle tracking, and a CurlEngine bug fix. §21 lists them.

## 2. Shape

```text
Microsoft Graph
      |
existing SyncEngine (sync.d) ----- applyPendingLocalChanges() <---- OnDemandChangeQueue
      |                                    (same LocalChange path         ^
      v                                     inotify feeds)                |   (today; §7)
item database (items.sqlite3)                                             |
  item.hydration = O | H | P                                              |
      |   ^                                                               |
      |   | select (shared connection)                                    |
      v   |                                                               |
HydrationService (hydration.d) <-- hydrate / ranged read / actions -- OnDemandFs (ondemand.d)
      |  downloads via OneDriveApi                              FUSE3, mounted on sync_dir
      v                                                               |
physical sync_dir  <------------- /proc/self/fd/<n> ------------------+
(hydrated files, all folders;      (directory fd opened before the mount;
 engine works here through          the engine's working directory also
 its working directory)             stays on the physical tree)
```

One process owns the engine, the database connection, the mount and the hydration service.

## 3. Where the fork matches the ADR

| ADR | Position | Fork |
|---|---|---|
| §2.3, §11 | FUSE over `sync_dir`, hydrated content physically in `sync_dir` | Yes (§6) |
| §5, INV-005 | The DB is the namespace authority | Yes. Online-only items are served from DB rows; no placeholder files |
| §6 | Stable hydration state in the DB | Yes, `item.hydration` (§5) |
| §7 | Narrow materialisation decision | Yes. New online files get `O` where they would be queued for download (`applyPotentiallyNewLocalItem`) |
| §9.1, INV-014 | Enumeration and stat do not hydrate | Yes. `open()` does not hydrate either, and file-manager sniffing is served with ranged reads (§10) |
| §13, INV-008 | Cloud-only absence is not deletion | Yes. The consistency check, `isItemSynced` and download-failure paths treat absent `O` as in sync |
| §14, INV-015 | User delete and dehydrate are distinct | Yes. They are separate operations |
| §15, INV-012 | Dirty content is never dehydrated | Yes. Free requires a hash match (§10) |
| §17.1 | Enabling on an existing tree reuses local files | Partly. Hash-matched files become hydrated after `--resync`, with no download |
| §18, INV-017 | Unmount or crash leaves hydrated files visible | Yes. After unmount, `sync_dir` shows hydrated files and all folders |
| §22 | FUSE3 bindings first | Yes (§4) |

## 4. FUSE3 foundation (ADR §22, Stage 1)

The vendored bindings in `src/c/fuse` and `src/fused` used FUSE2 callback signatures (two-argument `getattr`, `fgetattr`, `rename` without flags), while `configure.ac` linked libfuse3. We rewrote them for the libfuse 3 high-level API.

- ABI: the bindings target `FUSE_USE_VERSION 31` and are checked against libfuse 3.14 (`src/c/fuse/fuse.d`, `src/c/fuse/common.d`). `spike/abiprobe.c` and `spike/abiprobe.d` print field offsets and sizes from C and from D. The outputs are identical apart from a bitfield that C cannot `offsetof`.
- Minimum version: libfuse 3.12. `configure.ac` checks `fuse3 >= 3.12`, because the worker limit is set through `fuse_loop_cfg_*` (3.12 API). The tested version is 3.14, the Ubuntu 24.04 package.
- Lifecycle: `BackgroundFuse` in `src/fused/fuse.d` mounts and runs `fuse_loop_mt` on a background thread. It does not use `fuse_main()`, so libfuse installs no signal handlers and does not daemonise; the client's own handlers stay in charge. `stop()` calls `fuse_exit`, unmounts, joins with a 10 s timeout, and otherwise detaches lazily.
- Threads: libfuse worker threads attach to the D runtime on first use and detach from a pthread key destructor. An earlier version crashed in `pthread_detach` during runtime shutdown. Threads that may block on a request to their own mount are plain pthreads, so they cannot block the GC's stop-the-world signal.
- `dfuse_destroy` no longer calls `exit(0)`, which in the vendored code would have ended the client on unmount.
- The mount uses `fsname=onedrive,subtype=onedrive` (type `fuse.onedrive`) and `default_permissions`, plus `hard_remove` and `FUSE_CAP_ATOMIC_O_TRUNC`. It allows up to 64 worker threads (`onDemandMaxWorkerThreads`). With the libfuse default of 10, ten slow downloads blocked every other request.
- Minimal tests: `spike/hellofs.d` (20 concurrent readers, clean unmount) and `spike/chello.c` (a C reference).

## 5. Database and hydration state (ADR §5, §6)

- `item.hydration TEXT`: `O` online-only, `H` hydrated, `P` pinned. NULL means hydrated, so rows written in normal mode need no value. `itemDatabaseVersion` goes from 18 to 19 (`src/itemdb.d`) through the existing mismatch path, which rebuilds the item table. Upstream, an `ALTER TABLE` migration would be kinder.
- Upserts write the column with `COALESCE(?, hydration)`, so an engine metadata update never resets the state. Only `setHydration()` changes it.
- `ondemand_deferred (driveId, id, eTag)` persists online changes deferred while a file was open (§11).
- A marker file `<db>.ondemand` records which physical directory the database describes. It drives the refusals in §14 and the relocation in §6.
- Transient states (`syncing`, `pending`, `error`) are kept in memory, in a thread-safe per-item map (`transientStateOf` in `src/hydration.d`), not in the column.
- FUSE threads use the engine's single `ItemDatabase` object (`SQLITE_OPEN_FULLMUTEX`, `locking_mode = EXCLUSIVE`). They never open a second connection.

## 6. Physical layout (ADR §11, §17, §18)

The first version kept hydrated files in `<confdir>/ondemand/backing`, with the mount at `sync_dir`. That hid every downloaded file whenever the client was stopped. After reading ADR §11 we moved to the physical `sync_dir`.

### Mechanism: working directory plus a directory fd

The engine already works on relative `./` paths after `chdir(runtimeSyncDirectory)`. The fork keeps that and runs the `chdir(sync_dir)` before the mount. A process whose working directory was set before a mount keeps resolving relative paths on the covered directory, so the engine reaches the physical tree with few code changes. Before mounting, the client also opens `"."` with `O_DIRECTORY`. FUSE worker threads and `HydrationService` use that descriptor as `/proc/self/fd/<n>/...` (with a trailing slash on the root, because `lstat` of the bare magic link reports the link itself).

Spike evidence (passthrough FUSE over a test directory, Linux 7.0, libfuse 3.14; the spike scripts are not in the repository):
- Through `/proc/self/fd/<n>` opened before the mount, these all reach the covered physical tree: list, read, create, append, temp file plus rename, mkdir, move and unlink.
- inotify watches on the physical directory, added before or after the mount, receive events for changes made through the fd path. That is the path the FUSE layer writes through.
- A working directory set before the mount stays on the physical directory. `getcwd()` still returns the `sync_dir` string, though, and `chdir(getcwd())` lands on the mount.

The last point meant every place that turns `.` into an absolute path had to change: `pathIsProtectedByNoSync`, the relative-symlink check (now resolved against the link's directory with no `chdir`), the recycle-bin move, `getPathOwnerMismatch` in `util.d`, and `configuredBusinessSharedFilesDirectoryName`. The rule, written down in CONTRACT.md: an absolute path built from `sync_dir` resolves through the mount and must not be used for file access.

This needs fewer engine changes than retained-fd `*at()` calls everywhere, but it is Linux-specific. FreeBSD would need `*at()` calls or fdescfs for the FUSE side.

### Staging

Hydrations download into `<sync_dir>/.onedrive-ondemand:staging`, so the final `rename()` stays on one filesystem.
- OneDrive and SharePoint reject `:` in names, so no online item can collide with it.
- The FUSE layer hides it: ENOENT on lookup, not listed, EACCES on create or rename.
- The engine's local scan skips it (`isOnDemandStagingPath`).
- `HydrationService` removes leftovers at start; the item keeps `O`.

### Start-up order (`src/main.d`)

1. Option checks.
2. `prepareOnDemandPhysicalSyncDir()`:
   - Stale mount: `realpath(sync_dir)` is compared with the `fuse.onedrive` entries in `/proc/self/mounts`. A matching mount is probed with `statfs` in a child process under `timeout`.
     - If it answers, another client is running, and the start is refused.
     - If it times out, a client is hung, and the start is refused.
     - If it fails (ENOTCONN), the mount is dead and is unmounted with `fusermount3 -u -z`.
     - If `timeout` or `fusermount3` cannot be run, the start is refused.
   - Relocation: if the marker names another directory (the old backing directory, or the previous `sync_dir`), it is moved into place with one `rename()`. This needs the same filesystem and an absent or empty `sync_dir`; otherwise the start is refused and points at `--resync`. Nothing is copied, overwritten, uploaded or deleted.
     - An intent record, `<confdir>/.ondemand-move-intent`, is written before the rename and removed after the marker. A move interrupted in between is completed only when that record proves it.
     - Under `--dry-run`, nothing is moved or unmounted; the start is refused instead.
3. Database and marker check (§14).
4. `chdir(sync_dir)`, then the directory fd.
5. Missing content check: if the database records more than 5 hydrated or pinned files and none of them is present, the start is refused. This catches an unmounted disk or an emptied `sync_dir`.
6. The mount, then the first sync cycle.

### Shutdown and crash (ADR §18)

On shutdown the client stops the mount, then calls `HydrationService.shutdown()`. That cancels waiting callers with EIO and waits up to 30 s for in-flight transfers. Only then do the engine and the database shut down. After unmount, `sync_dir` shows hydrated files and all folders (test P1).

After a crash, the next start unmounts the dead mount and removes staging leftovers. Changes made while the client was stopped are handled as in normal mode:
- A changed or new file is uploaded.
- An absent `H` or `P` file is a real delete.
- A rename is a delete plus a new file.
- Absent `O` items stay in sync.

On top of that:
- A file put at the path of an `O` item while the client was stopped never overwrites the online version. With the online content it becomes `H`; otherwise it is kept as a `safeBackup` conflict copy.
- Content written through the mount over an `O` item (`O_TRUNC`, truncate to 0, save by rename) sets `H` at once. A stop before the upload therefore leaves an ordinary modified file, which is uploaded with the usual conflict check.
- The online deletes queued in one consistency pass are totalled (a folder counts with its children) against `classify_as_big_delete`. If the total reaches it, none is sent and the client exits, unless `--force` is given. The per-item check alone never trips here, because an emptied `sync_dir` deletes its files one at a time.

### Folders

Every folder in the database exists physically, created by the engine as in normal mode. While unmounted, the whole folder tree is visible, with files only where hydrated. This is our answer to ADR open decision 18.

### Live migration

On the author's drive, the switch from the backing directory moved 34 files and 779 folders into `sync_dir` with one `rename()`. The first cycle afterwards had 0 uploads, 0 deletes and 0 downloads.

## 7. Local change detection (ADR §10, INV-004, INV-011)

### What the fork does

The FUSE layer reports each change it makes to the physical tree (`changed`, `createDir`, `deleted`, `moved`) into `OnDemandChangeQueue` and wakes the main loop. `applyPendingLocalChanges()` in `src/main.d` appends these changes to `filesystemMonitor.takePendingChanges()` as ordinary `LocalChange` values, and from there the engine handles them exactly as it handles inotify events. FUSE never calls Graph for uploads, moves or deletes. The inotify monitor is not started in on-demand mode, and FUSE is the only writer of the physical tree while mounted.

### Why it was built this way

Every file operation passes through the FUSE layer, which therefore knows what happened, to which item, and for whom. Reporting that directly avoided having to reconstruct intent from inotify events. That reconstruction is hardest exactly where on-demand adds new operations: frees, hydrations and online-only items.

### What this gives

- Free and delete are explicit. Freeing a file removes it physically but sends nothing to the engine; a user `unlink` sends `deleted`. No rule has to tell the two apart afterwards (INV-015).
- Hydration writes are never misread as local changes. A hydration writes into staging and renames into place. Engine downloads and conflict-copy renames work the same way.
- Open/close and caller identity are known. Deferring online changes while a file is open (§11), refusing to free an open file, the thumbnailer guard (§13) and the reader classes for ranged reads (§10) depend on them.
- One upload per save. A write is reported on `release()` of a handle that was written, with no debounce timing.

### What a swap to the existing inotify path would mean

- Suppressing the client's own writes: frees, hydration renames, conflict copies and engine downloads must not reach the engine as local changes.
- Tests showing that a free never becomes an online delete, including under concurrent frees, user deletes and restarts.
- Debounce and save-by-rename handling as in normal mode (`IN_CLOSE_WRITE`, temp file plus rename), in place of the per-handle report.
- Watches on the physical tree set up before the mount. The spike shows that inotify on the physical tree sees changes made through the fd path, which is how FUSE writes.

Open/close tracking and caller identity would stay in the FUSE layer either way, since inotify does not provide them.

One point the ADR does not cover: namespace operations on online-only items. Deleting, renaming or moving a cloud-only file through the mount touches no physical file, so inotify sees nothing. Today `unlink` of an online-only file emits `deleted` with no physical change (`src/ondemand.d`). A rename of an online-only file currently hydrates it first, which is a gap of its own (§20). Even after a swap, then, the mount would have to report these operations to the engine itself, which makes the design a hybrid. This is our reading of the design; we have not tested it. We would like to raise it as an open question for the ADR: §4.2 says only that cloud-only files have no content to monitor, not how namespace changes to them reach the engine.

### Our offer

If the existing inotify path is a hard requirement upstream, we will swap, and the fork will take that step.

## 8. Pinning as a hydration state (ADR §6.3, §16)

What the fork does: "Always keep on this device" sets `P` in the same column as `O` and `H`.
- On a file, `P` means resident and retained. `pin()` hydrates first and sets `P` only once the file is present.
- On a folder, `P` acts as a policy. New online files below it download immediately, and a free below it is refused unless explicit.

Reason: we followed the Windows client, where the pin is a per-item attribute set from the file manager.

Benefit: one read gives residency and retention, both change under the same lock, and there is nothing else to keep consistent.

Cost of following the ADR: a policy store and its precedence against `sync_list` and skip rules (ADR §16) have to be designed. The current cost of the state model goes away in exchange:
- Pins live in the database and would be lost on `--resync`; `src/ondemandpins.d` saves and restores them.
- They cannot be set in configuration.
- They conflate retention with residency.

We would follow the ADR model: `always_local` replaces folder `P`, a pinned file becomes `H` plus a policy match, and `ondemandpins.d` goes away. The xattr and file-manager interface (§11) can stay on top of the policy.

## 9. `on_demand` and `--monitor` (ADR §4, INV-002)

What the fork does: `--sync` with `on_demand = true` is refused with "ERROR: --on-demand can only be used with --monitor" (`checkForBasicOptionConflicts` in `src/config.d`). `--upload-only` and `--download-only` are refused too.

Reason: one process owns the engine, the exclusive database connection and the mount. A single sync exits after one pass, so its mount would vanish at once, and hydration needs a running engine.

Benefit: one lifecycle to get right while the rest was experimental.

Cost of following the ADR: a single sync with `on_demand` runs without a mount. It updates the database, records new files as `O`, downloads policy-required content and uploads physical changes. The offline-change rules in §6 already cover a pass over the physical tree with no mount, so the cost is mainly testing.

We would follow the ADR. It is not built yet.

## 10. Hydration, ranged reads and dehydration (ADR §9, §15)

### What hydrates

- These hydrate: `read` by an application, `write`, `truncate` to a non-zero size, the `download` and `pin` actions, and `rename` of an online-only file. The rename case is a known gap.
- These do not: `open`, `getattr`, `readdir`, xattr reads, and `open` with `O_TRUNC`, which creates an empty file.
- Reads by file managers, indexers and scanners are served without hydration (below).

### Concurrency

`HydrationService.hydrate()` keeps an in-flight map keyed by (driveId, id). Later callers wait for the one download. Test: "10 concurrent cat".

### Download path

`HydrationService` uses `OneDriveApi.getPathDetailsById` and `downloadById`, with the same hash validation, `disable_download_validation` and `space_reservation`. It does not call `SyncEngine.downloadFileItem`, because the engine's arrays are not synchronised and FUSE requests arrive on worker threads.

### Hydration commit order

1. Download into staging and verify the hash.
2. Under the state lock, re-read the DB row:
   - a different online version applied meanwhile: start again;
   - the item moved: start again;
   - a file already at the target: keep it, never overwrite;
   - a missing parent: EAGAIN (parents are never created).
3. Set the mtime from the DB, `rename()` into place, then set `H` (or `P` if pinned).

A crash before the rename leaves a staging leftover, which is removed at the next start. A crash after the rename but before the DB write leaves a present file with `O`, which the stopped-client rule in §6 resolves by hash.

### Ranged reads for background readers

A file manager sniffs the content type of files and reads previews while the user browses. In the first daily use this downloaded files nobody had asked for. The caller cannot tell a sniff from a copy: Nautilus does both on the same worker threads. So the read volume decides. A file is downloaded only after a deliberate user action: opening it in an application, copying or moving it, or a OneDrive action.

At `open`, the caller is classified by its process name and executable. The thread name is not used, because file managers read on generic worker threads.

| Reader | Examples | Behaviour |
|---|---|---|
| File manager | nautilus, nemo, caja, thunar, dolphin, pcmanfm | Ranged reads. A handle that reads more than 1 MiB in total (a copy or move) gets the file downloaded, and the rest is read locally. Files of 1 MiB or less stay online-only |
| Background service | gvfsd, tracker, localsearch, baloo, zeitgeist | Ranged reads up to 4 MiB per handle, then EIO. Never downloads |
| On-access scanner | ClamAV, Defender for Endpoint, CrowdStrike, Sophos, ESET | As background services, except that a scanner reading during a user's open joins that open's download |
| Thumbnailer | §13 | Refused |
| Any other process | applications | Downloads on the first read |

How ranged reads work (`HydrationService.readRange`, `OneDriveApi.getDownloadUrlById`, `downloadRangeByUrl`):
- Request: the item's `@microsoft.graph.downloadUrl` is fetched, then one GET with `Range: bytes=a-b`, a 30 s timeout and an abort on shutdown.
- Cache: 128 KiB blocks, keyed by item and content version (content hash, else cTag, else eTag). It is capped at 64 MiB, and items are dropped 60 s after their last read.
- Version safety:
  - A handle records the content version at its first ranged read.
  - If the database item changes between two reads, that read and all later reads on the handle fail with EIO. So does a file manager's escalation that downloads a different version from the part already served. Versions are never mixed within a handle.
  - The `Content-Range` total must equal the database size.
  - A changed response ETag for a cached version fails the read.
  - Each new download URL must come with the expected version and size.
- Offline: a ranged read fails with EIO at once.
- Lock rule: no state, transaction or database lock is held across network I/O.

The scanner case: a fanotify scanner reads a file during the user's `open()`, before that open reaches the mount. Its read joins the download when a user handle is open, a download is in flight, or a normal process looked the item up in the last second. This is a heuristic. A lookup served from the kernel's attribute cache is not seen.

This is a new read path to Graph next to the existing download, owned by `HydrationService`, not by FUSE. ADR §9.2 allows only "read hydrated content, or hydrate". Ranged reads add a third option for metadata-like reads. We would like your view on whether that belongs upstream.

Live result on a Personal drive:
- Nautilus browsing was served 32 KB content sniffs without any download.
- A Nautilus copy of a 3.8 MB zip escalated past 1 MiB and hydrated, and the copy was byte-identical to the source.
- Opening a PDF in a document viewer hydrated it.
- Graph's `downloadUrl` honoured `Range` on Personal. We have not checked it on Business.

### Dehydration ("free up space")

Order, under the state lock:
1. Refuse if the file is open (EBUSY). If every open handle belongs to an on-access scanner, wait up to 5 s first, since scanners open new files briefly.
2. Refuse if it is pinned, unless the request names that file explicitly, as on Windows. The parent folder stays pinned.
3. Refuse if the file does not match the DB hash, meaning a local change.
4. Write `O`, then remove the file. If the removal fails, restore the previous state.

Writing `O` first means an absent file is never paired with `H`. A crash in between leaves `O` with a present file, which the §6 rule resolves. There is no automatic dehydration: no cache limit and no expiry. Folder actions run on a background worker and log per-file refusals.

## 11. Behaviour that follows the Windows client (ADR §19, §20)

- Online change to an open file: if an `H` or `P` file is open through the mount, a newer online version is deferred and persisted in `ondemand_deferred`, and the state shows `pending`. On the last close, the item is fetched again and applied only if it is unchanged since the deferral (eTag, name, parent). Otherwise the next delta applies it.
- Conflict check before uploads: every modified upload in on-demand mode first compares the online item with the DB baseline by size and hash, and checks for a deferral. If the item changed online, the local version is kept as a `safeBackup` copy, uploaded as a new file, and the online version is applied. A review found that the earlier mtime-only check let a local save overwrite a deferred online change.
- Locked online (HTTP 423): the upload is retried after 30 s, 60 s and 120 s, then every monitor interval (`lockedUploadRetrySeconds`). Live, a spreadsheet open in Excel for the web uploaded on a later retry while still open.
- Save by rename: editors that write a temp file and rename it over the original (LibreOffice, File Roller) produced a move from a path the DB does not know. The engine then queued no upload until the next full scan. In on-demand mode the destination is now uploaded at once (`uploadMoveItem` in `src/sync.d`). Normal mode takes the same code path and may have the same delay; we have not checked.
- Folder actions: download, pin and free work recursively. In Nautilus, freeing a folder asks for confirmation, and it is not offered on the drive root.
- Extended attributes on paths in the mount are the only interface for the CLI and the file manager:

| xattr | Access | Values |
|---|---|---|
| `user.onedrive.state` | read | `online-only`, `hydrated`, `pinned`, `local` (not in the DB yet), `syncing`, `pending`, `error` |
| `user.onedrive.action` | write | `download`, `pin`, `unpin`, `free` |
| `user.onedrive.pin` | write | `1`/`0`, an alias for pin/unpin |
| `user.onedrive.weburl` | read | Graph `webUrl`, fetched on demand, cached per eTag |

`st_blocks` is 0 for online-only files, so `du` shows real local use.

## 12. FUSE caching, invalidation and file-manager refresh (ADR §8, §21)

- Namespace: there is no FUSE-side copy.
  - `lookup`, `getattr` and `readdir` query the database on each call.
  - `readdir` returns the DB children plus the physical entries, so local items that are not yet uploaded are visible.
  - `getattr` uses `lstat` when a file is physically present, DB metadata otherwise.
  - A 2 s cache of folder states is invalidated by a generation counter on every hydration-state write.
- Pending operations: after a FUSE `unlink` or `rename`, the deleted item and the moved-away path stay hidden in memory until the engine writes the change to the database. A DB item replaced by an editor's rename-over is shown again after 5 minutes if the engine has not acted on it. A download through a path with a pending move waits up to 30 s, then returns EAGAIN.
- Kernel caches: libfuse high-level defaults (1 s entry and attribute timeouts, no negative entry caching, page cache dropped on open). Not measured at large scale.
- File-manager refresh: when the engine changes the physical tree, an inotify watcher on the mount (Nautilus through GIO) sees nothing.
  - `ondemand/test/notify-matrix.sh` tried `fuse_lowlevel_notify_inval_entry`, `notify_delete`, `notify_inval_inode` and `fuse_invalidate_path` on kernel 7.0 with libfuse 3.14. None produced inotify events on the mount.
  - The fix is a replay thread. For each engine change it makes a matching no-op syscall on the mount. FUSE recognises the replay thread by its kernel thread id from `fuse_get_context()` and answers without touching anything, and the kernel then emits real events.
  - If the thread id is not known within 10 s, notifications stay off (fail closed, `notifier-start-test.sh`).

## 13. Thumbnails (ADR open decision 13)

- Pre-seeding:
  - After each sync cycle, `ThumbnailService` (`src/thumbnails.d`) fetches Graph thumbnails for online-only files and converts them to PNG with `gdk-pixbuf-thumbnailer`.
  - It adds `Thumb::URI` (the file's URI in the mount) and `Thumb::MTime`, and writes them to `$XDG_CACHE_HOME/thumbnails/{normal,large}/<md5(uri)>.png` per the freedesktop spec.
  - Nautilus 46 then uses the cached thumbnail and launches no thumbnailer.
  - The service never reads files in the mount, and `on_demand_thumbnails` turns it off. On the author's drive, 2,438 thumbnails were written on the first full day, with no hydration from browsing.
- Backstop: a read by a known thumbnailer (gdk-pixbuf, evince, totem, ffmpegthumbnailer, gnome-thumbnailer, tumblerd) fails with EIO and downloads nothing. The caller is identified from `fuse_get_context()` and `/proc/<pid>/comm` and `exe`. We have not verified pid resolution for thumbnailers inside GNOME's bwrap sandbox.

## 14. Safety guards (ADR §13, §16, §17)

- Option classification: `ondemand/OPTIONS.md` classifies all 97 config keys: 70 relevant, 4 relevant-ondemand, 10 ignored, 9 refused, 4 risky. The refused keys are `upload_only`, `download_only`, `dry_run`, `mirror_local_state` and the five CLI-only `on_demand_cli_*` keys.
- Refusals:
  - A normal-mode run on a database built in on-demand mode (marker present, or any `O` row) is refused, because every online-only file would look locally deleted.
  - An on-demand run on a database built in normal mode is refused unless the database is empty.
  - `--resync` converts in either direction.
  - `mirror_local_state` is refused: with `local_first` it would delete online what is online-only here.
  - `dry_run` is refused: it fakes engine transfers while the mount changes real data.
  - A `recycle_bin_path` inside the mount is refused.
- Big deletes and missing content: §6.
- Pins across `--resync`: saved and restored (§8). Live, an automatic whole-drive resync restored 3 of 3 pins.
- Moving the mount: changing `sync_dir` moves the physical directory with `rename()` at the next start, with no `--resync`, if it stays on the same filesystem.
- One-shot resync: `--on-demand-resync-once` resyncs, completes the first cycle and restores pins, then exits. It checks authentication and reachability before wiping the database.

## 15. Desktop integration and tooling (ADR Stage 9)

- D-Bus status interface:
  - Interface `io.github.abraunegg.OneDrive1` at `/io/github/abraunegg/OneDrive` on the session bus (`src/dbusstatus.d`).
  - Each confdir gets its own bus name: `io.github.abraunegg.OneDrive.i<first 16 hex chars of sha256(confdir)>`.
  - Methods: `GetTransfers`, `GetIssues`, `DismissIssue`, `SyncNow`, `Pause`, `Resume`.
  - Signals: `PropertiesChanged`, `IssuesChanged`, `TransfersChanged`.
  - It works in normal mode too. `dbus_status` defaults to true in the fork; upstream it should probably default to false.
- CLI: `--download`, `--pin`, `--unpin`, `--free` and `--status <path>`, implemented as xattr calls on the mount (`src/ondemandcli.d`).
- Nautilus extension (`contrib/nautilus/onedrive-ondemand.py`): state emblems, a list column, and a "OneDrive" submenu (View online, Download now, Always keep / Stop keeping on this device, Free up space).
- Debian package (`contrib/ondemand`):
  - systemd user units for one or many profiles, without sandboxing, because a private mount namespace would hide the mount;
  - a one-shot resync unit;
  - setup, unmount and resync helpers with man pages.
- GUI: a fork of OneDriveGUI (github.com/paalkr/OneDriveGUI, branch `ondemand/dbus-gui`). It attaches to running clients over D-Bus, with a tray, a status window, a Basic settings page, service start and stop, and resync through the unit. It is capability-gated, so it behaves like upstream against a stock client.

## 16. A bug found on the way: CurlEngine finalised at exit

Long runs sometimes ended with SIGSEGV (exit 139) after the last log line. Under gdb, the crash was `std.net.curl.HTTP.shutdown()`, called from `CurlEngine.__aggrDtor` inside the GC's final collection in `exit()` after libcurl was gone.

The cause is `getCurlInstance()` in `src/curlEngine.d`. In two branches it drops pooled engines without destroying them: when the engine is stopped, and when it has been idle longer than `max_curl_idle`. The GC then finalised those engines at exit.

Fix:
- e2d0983: destroy discarded engines immediately, return early from `~this` under `GC.inFinalizer()`, and log the number of instances still alive at shutdown.
- f45b026: keep the `HTTP` struct in malloc'd memory, so that no finaliser or field destructor calls libcurl.

Since the fix, every stop has logged "CurlEngine instances still alive at shutdown: 0". That covers seven long runs under gdb (up to 12 h) and all daily use since. The bug affects normal mode too, and the fix is independent of on-demand.

## 17. ADR open decisions (§26)

| # | Decision | Fork today | Where |
|---|---|---|---|
| 1 | Hydration schema | `item.hydration TEXT` O/H/P, NULL = hydrated; schema 19; `ondemand_deferred` table | `src/itemdb.d` |
| 2 | Is a boolean enough? | For stable state, yes. The third value exists only because pin shares the column (§8). Transient states are kept elsewhere | `src/itemdb.d`, `src/hydration.d` |
| 3 | Transient operations that survive restart | Deferred online changes (DB table), pins across `--resync` (JSON), the move intent record. Staged downloads are discarded. Lock retries and transient states are memory-only; the next cycle finds the change again | `src/itemdb.d`, `src/ondemandpins.d`, `src/main.d` |
| 4 | How FUSE learns about DB changes | No FUSE namespace copy; every lookup reads the DB. Engine changes are replayed on the mount | §12 |
| 5 | Kernel cache policy | libfuse defaults. Not measured at scale | §12 |
| 6 | Retained fd plus `*at()`? | `chdir(sync_dir)` before the mount for the engine, and an `O_DIRECTORY` fd as `/proc/self/fd/<n>` for FUSE threads. Linux-only | §6 |
| 7 | Does inotify see FUSE-routed mutations? | On the physical tree, yes, for changes through the fd path (spike). Not used yet (§7). On the mount, engine changes need the replay thread | §6, §7, §12 |
| 8 | When watches and the mount are set up | Today: prepare, DB check, chdir and fd, missing-content check, mount, first cycle. With inotify (§7), watches go on the physical tree before the mount | §6 |
| 9 | Serialising concurrent hydrations | In-flight map per item; ranged reads use a per-item fetch lock | §10 |
| 10 | Hydration commit order | Staging, hash, re-check under lock, rename, then H/P | §10 |
| 11 | Dehydration commit order | Checks under lock, write O, remove, restore on failure | §10 |
| 12 | What counts as content demand | Application reads, writes, non-zero truncate, rename of an O file (a gap), and download/pin. File managers only past 1 MiB per handle. Indexers and scanners never (ranged reads up to 4 MiB) | §10 |
| 13 | Thumbnails without hydration | Pre-seeded freedesktop cache from Graph, plus refusal for thumbnailers | §13 |
| 14 | Disabling `on_demand` | Not built. Normal mode refuses an on-demand DB; `--resync` converts it. Untested | `src/main.d` |
| 15 | `always_local` vs filters | Not built. Pins exist only on items that passed filtering; we would follow the ADR policy model | §8 |
| 16 | Combinations to reject | 9 keys refused, 4 risky, all 97 classified | `ondemand/OPTIONS.md` |
| 17 | Linux/FreeBSD differences | Not addressed. Linux-specific today: `/proc/self/fd`, `/proc/self/mounts`, `/proc/<pid>`, `fusermount3`, the Linux xattr calls | §6 |
| 18 | Physical folders with all-O descendants | Every DB folder exists physically | §6 |
| 19 | Local-only items before a Graph id | Present only physically. `readdir` merges physical entries and the state is `local`; after upload the row is `H` | §12 |
| 20 | DB unavailable or inconsistent | Partly. FUSE uses the engine's one connection and waits on its lock; pending moves wait 30 s then EAGAIN; shutdown cancels waiters with EIO | §12 |

## 18. Invariants (ADR §23)

| INV | Status | Evidence |
|---|---|---|
| 001 Disabled means existing behaviour | Holds, with exceptions | Engine paths are gated on `on_demand`. Exceptions: the schema bump rebuilds the item table, the D-Bus service is on by default, and the CurlEngine fix changes normal mode (deliberately) |
| 002 Orthogonal to `--monitor` | Not yet | §9 |
| 003 Remote monitoring covers the namespace | Holds | Delta, WebSocket and webhook paths are unchanged; O items are updated without download |
| 004 Local monitoring applies to resident content | Not yet in the ADR form | FUSE events instead of inotify; swap offered if required (§7) |
| 005 DB is the namespace authority | Holds | §12 |
| 006 `sync_dir` stays the user path | Holds | §6 |
| 007 Hydrated means valid content | Holds | H after hash check and rename |
| 008 Cloud-only absence is expected | Holds | Consistency check, `isItemSynced`, download-failure paths; tests in `run-test.sh` and `test-physical` |
| 009 FUSE is not a sync engine | Holds | FUSE never calls Graph for uploads, moves or deletes |
| 010 Hydration reuses the download path | Partly | Same `OneDriveApi` download and validation, not `downloadFileItem`. Ranged reads are a separate read path (§10) |
| 011 Edits use existing local-change processing | Partly | Same `applyPendingLocalChanges` processing, but the events come from FUSE; swap offered if required (§7) |
| 012 Dirty content wins | Holds | Free requires a hash match; no automatic dehydration |
| 013 Ambiguity favours preservation | Holds | Never overwrite at commit, EAGAIN on a missing parent, conflict copies, missing-content and big-delete guards |
| 014 Enumeration does not hydrate | Holds | `readdir`, `getattr` and `open` never hydrate; sniffing is served by ranged reads; thumbnails are pre-seeded |
| 015 Delete and dehydrate are distinct | Holds | Separate operations; it must stay so under inotify (§7) |
| 016 State follows the storage transition | Holds | H after rename, O before remove |
| 017 FUSE loss keeps hydrated data | Holds | Physical layout, test P1, stale-mount recovery |
| 018 No competing namespace truth | Holds, with a short-lived overlay | A pending unlink or rename stays hidden in memory until the engine writes it to the DB (§12) |

## 19. Validation (ADR §25)

Test suites, all run on `ondemand/main` at b6e8629. They need no account, and they mount only under `$TMPDIR`.

| Suite | Checks | Covers |
|---|---|---|
| `ondemand/test/run-test.sh` | 201 | The real `src/ondemand.d` and `itemdb.d` against a stub hydration service: browsing, hydration, O_TRUNC, writes, renames, editor saves, actions, free refusals and the scanner wait, thumbnailer refusal, reader classes and ranged reads, transient states, deferral, replay notifications, hidden staging, unmount shows files |
| `ondemand/test/notifier-start-test.sh` | 6 | The replay thread fails closed |
| `ondemand/test-physical/run.sh` | 68 | The real client and `HydrationService`: stale and live mounts, migration, `sync_dir` move, intent record, refusals, dry-run, missing content, big-delete totals, content over O items, crash between staging and rename, ranged-read cache and version checks, free with scanners |
| `ondemand/test-dbus/run-dbus-test.py` | 28 | D-Bus properties, methods, introspection, per-confdir names |
| `ondemand/test-pins/run.sh` | 1 | Pins resolve after a resync, by id and by path |

Live use on OneDrive Personal:
- The first runs used a test folder: hydration on open, pin, free, uploads, renames, deletes, conflict copies, deferral, lock retries.
- Since 2026-10-02 the client has run against the whole drive as a systemd user unit.
  - The automatic whole-drive resync took about 4 minutes, with 0 uploads, 0 deletes and 0 downloads, and restored 3 of 3 pins.
  - The first full day had 8 starts and 8 clean stops, no crashes, 4 modified uploads, 0 online deletes, 3 hydrations and 2,438 thumbnails written.
- The physical layout went live on 2026-10-03 (§6). Ranged reads went live on 2026-10-04 (§10).

Not yet tested: OneDrive Business, SharePoint libraries, shared folders and files, FreeBSD, very large namespaces, disk-full during hydration.

## 20. Not done, and known gaps

- Local changes through inotify (§7), `always_local` as policy (§8), and `on_demand` with a single sync (§9).
- Open question for the ADR: how delete, rename and move of online-only items reach the engine when no physical file changes (§7).
- Turning `on_demand` off again (ADR §17.2).
- Cache size limits and expiry.
- Shared items, SharePoint and Business in on-demand mode.
- FreeBSD.
- Renaming an online-only file hydrates it first.
- A handle opened on the physical file before the mount, or while the client was stopped, is not counted as open.
- KDE's kioworker is not among the reader classes, so it downloads on read.
- The scanner heuristic (§10) can miss a user open when the lookup was served from the kernel's attribute cache.

## 21. Pieces that could be offered upstream

These do not depend on the change queue, the pin state or monitor-only mode. Each can be built and tested on its own, with `on_demand = false` unchanged.

1. CurlEngine finalisation fix (§16). It is independent of on-demand, small, and affects normal mode today.
2. FUSE3 bindings and portability (§4): `src/c/fuse` and `src/fused` (`BackgroundFuse`, thread attach and detach, no signal handlers), the `fuse3 >= 3.12` check, the ABI probe and hellofs.
3. Hydration concurrency (§10): one download per item for concurrent callers, staging inside `sync_dir`, and the commit order with its re-checks under the state lock.
4. Safe dehydration semantics (§10): the refusal rules (open, pinned, hash mismatch), the `O`-before-remove order, and the crash rule that resolves a present file with `O` by hash.
5. Open-handle tracking (§11): `noteOpen`/`noteClose` per item, used to refuse frees and to defer online changes to open files, including the scanner-aware wait.

The physical layout (§6), the ranged reads (§10), the pre-seeded thumbnails (§13) and the D-Bus interface (§15) are further candidates once the ADR stages they belong to are reached. §7 to §9 we would align with the ADR model as discussed there. The code is on branch `ondemand/main` of github.com/paalkr/onedrive.
