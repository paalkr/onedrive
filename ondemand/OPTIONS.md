# Config options in on-demand mode

Every option the config file accepts: the keys with defaults in `ApplicationConfig.initialise()` (src/config.d:317-614); the config file parser (src/config.d:1004-1110) accepts exactly those keys. Line numbers are against `ondemand/main` at 8f3c350.

On-demand facts used below:
- The engine works on the backing directory (`runtimeSyncDirectory`). `sync_dir` is the FUSE mountpoint.
- inotify is not started (main.d `!download_only && !on_demand` around the monitor initialisation). Local changes come from the FUSE layer.
- The mount reports an online-only file as `S_IFREG|0600` and a directory known only to the database as `S_IFDIR|0700`. Anything present in the backing dir gets the `lstat` of the backing file (src/ondemand.d:90-91, 503-506, 628-636). It mounts with `default_permissions` (src/ondemand.d:761).
- The FUSE layer implements no `symlink`/`readlink` override (src/ondemand.d), so no symlinks can be created through the mount.

Status values:
- `relevant`: works as in normal mode.
- `relevant-ondemand`: on-demand specific.
- `ignored`: accepted, but has no effect in on-demand mode.
- `refused`: the client refuses to start with it in on-demand mode.
- `risky`: works, but interacts with on-demand safety.
- `unknown`: not verified.

`R` marks an option checked by `applicationChangeWhereResyncRequired()` (src/config.d:2094; the keys are listed at src/config.d:2136-2150, plus the sync_list file hash).

| option | on-demand status | reason | file:line |
|---|---|---|---|
| application_id | relevant | Authentication only | config.d:317 |
| log_dir | relevant | Logging only | config.d:318 |
| skip_dir (R) | relevant | Client-side filtering. Excluded online items are not recorded, so they do not appear in the mount. A matching folder created through the mount stays local only (in the backing dir). | config.d:319, 1081 |
| skip_file (R) | relevant | As skip_dir, for files | config.d:320, 1074 |
| sync_dir (R) | relevant-ondemand | It is the mountpoint. Data lives in the backing dir. | config.d:321, 1064; config.d initialiseRuntimeSyncDirectory |
| user_agent | relevant | HTTP | config.d:322; onedrive.d:280 |
| drive_id (R) | relevant | SharePoint library selection | config.d:324 |
| azure_ad_endpoint | relevant | National cloud endpoints | config.d:340 |
| azure_tenant_id | relevant | Authentication | config.d:342 |
| transfer_order | relevant | Order of engine download/upload batches. Hydrations are on demand and not ordered. | config.d:350 |
| monitor_authoritative_sync | ignored | Only consulted with download_only + cleanup_local_files, which on-demand refuses | config.d:354; main.d:1572; sync.d:1181 |
| use_recycle_bin | risky | Online deletions move backing-dir files to the recycle bin (online-only files have no local file, so nothing moves). The "recycle bin inside sync_dir" check compares against the backing dir, not the mountpoint (config.d:3128-3150, main.d:380-391). A recycle_bin_path inside the mount passes the check. rename() from the backing dir into the mount then fails (EXDEV), the move fails, and the delta checkpoint is held back on every cycle (sync.d:6148 onwards). | config.d:358 |
| recycle_bin_path | risky | See use_recycle_bin | config.d:360 |
| verbose | relevant | Logging | config.d:363 |
| monitor_interval | relevant | Sync cycle interval. Also the long interval of locked-online retries. | config.d:365 |
| skip_size (R) | relevant | Filtering. Larger online files are not recorded, so they are not visible in the mount. | config.d:367 |
| monitor_log_frequency | relevant | Log suppression | config.d:369 |
| monitor_fullscan_frequency | relevant | Online full-scan true-up | config.d:373 |
| classify_as_big_delete | relevant | Applies in uploadDeletedItem (sync.d:12768). `rm -r` through the mount emits one delete per file (like inotify), so it rarely triggers, as in normal monitor mode. Absent hydrated files found by the consistency check are counted as usual. Online-only files are never counted as deleted. | config.d:375 |
| sync_dir_permissions | relevant | Applied to backing-dir folders created by the engine. Visible through the mount for folders present in the backing dir. Database-only folders show 0700. | config.d:377; ondemand.d:503-506, 628-630 |
| sync_file_permissions | relevant | Applied to downloaded/hydrated backing files and visible through the mount (lstat). Online-only files always show 0600. | config.d:379; hydration.d (filePermissions); ondemand.d:631-632 |
| rate_limit | relevant | Applies to engine transfers and hydrations (same CurlEngine) | config.d:381; onedrive.d:280 |
| space_reservation | relevant | Download and hydration free-space check | config.d:383; hydration.d (spaceReservation) |
| file_fragment_size | relevant | Session uploads | config.d:385 |
| operation_timeout | relevant | HTTP | config.d:392 |
| dns_timeout | relevant | HTTP, connectivity probe | config.d:394 |
| connect_timeout | relevant | HTTP, connectivity probe, thumbnails | config.d:397 |
| data_timeout | relevant | HTTP, thumbnails | config.d:399 |
| ip_protocol_version | relevant | HTTP | config.d:401 |
| max_curl_idle | relevant | CurlEngine pool | config.d:403 |
| threads | relevant | Engine transfer pool. Hydrations run on FUSE threads and are not limited by it. | config.d:406 |
| upload_only | refused | "--on-demand cannot be used with --upload-only or --download-only" | config.d:409; config.d checkForBasicOptionConflicts |
| check_nomount | ignored | Checks for `.nosync` in the working directory, which is the backing dir under the confdir. It no longer detects an unmounted sync_dir disk. | config.d:411; main.d:2820 |
| check_nosync (R) | relevant | `.nosync` in a folder of the backing dir (created through the mount) protects it as in normal mode | config.d:413; sync.d:2612, 2948, 7439 |
| download_only | refused | See upload_only | config.d:415 |
| on_demand | relevant-ondemand | Requires --monitor. Database marker checks (main.d checkOnDemandProfileState). | config.d:417 |
| on_demand_backing_dir | relevant-ondemand | Backing dir. A change requires --resync (marker records it). | config.d:419 |
| dbus_status | relevant-ondemand | D-Bus status interface, both modes | config.d:421 |
| on_demand_thumbnails | relevant-ondemand | Thumbnails for online-only files | config.d:423 |
| on_demand_cli_download, _pin, _unpin, _free, _status | refused (in the config file) | CLI only. Ignored with a warning in the config file. | config.d:425-429, 1024-1031 |
| disable_notifications | relevant | Desktop notifications | config.d:431 |
| disable_download_validation | relevant | Honoured by engine downloads and hydrations (hydration.d verifyDownload) | config.d:434 |
| disable_upload_validation | relevant | Uploads | config.d:437 |
| enable_logging | relevant | Logging | config.d:439 |
| force_http_11 | relevant | HTTP | config.d:442 |
| local_first | relevant | Local-first ordering of the standard sync (main.d:2125). The consistency check treats an absent online-only file as in sync, so a local-first pass deletes nothing extra. Dangerous only together with mirror_local_state (below). | config.d:444 |
| no_remote_delete | ignored | Only valid with upload_only, which on-demand refuses (config.d "--no-remote-delete can only be used with --upload-only") | config.d:446 |
| skip_symlinks (R) | ignored | Symlinks cannot be created through the mount (no symlink operation). Only external writes into the backing dir could create one, and those are unsupported. | config.d:448; sync.d:7557, 9946 |
| debug_https | relevant | Diagnostics. Pre-signed thumbnail URLs are redacted (curlEngine.d redactUrlValues). | config.d:450 |
| skip_dotfiles (R) | relevant | Filtering | config.d:452 |
| dry_run | risky | Uses a copy of the database and fakes engine transfers. The mount runs normally. FUSE writes, deletes and renames change the real backing dir. HydrationService downloads and frees real files. A dry run therefore modifies local data while the engine pretends not to, and its DB copy diverges from the backing dir. See "Should be refused". | config.d:454; main.d:510 |
| sync_root_files | relevant | sync_list | config.d:456 |
| remove_source_files | ignored | Only valid with upload_only (refused) | config.d:458 |
| remove_source_folders | ignored | Only valid with upload_only (refused) | config.d:460 |
| skip_dir_strict_match | relevant | Filtering | config.d:462 |
| resync | relevant | Rebuilds the database. Required after switching modes or the backing dir (main.d checkOnDemandProfileState). | config.d:464 |
| resync_auth | relevant | Authentication | config.d:466 |
| bypass_data_preservation | risky | No safeBackup conflict copies. The on-demand conflict path (local save while the file was open plus a newer online version) then replaces the local version without a copy. That is upstream semantics for this option, but on-demand defers more often (any open file). | config.d:469; sync.d:640 |
| sync_business_shared_items (R) | risky | Shared (remote) items are out of scope for on-demand. HydrationService refuses them (EIO), and the engine downloads shared files as in normal mode (applyPotentiallyNewLocalItem queues remote files). Actions and free do not apply to them. | config.d:471 |
| display_running_config | relevant | Display | config.d:473 |
| read_only_auth_scope | relevant | Uploads fail; local edits through the mount stay local. Free is refused for files that differ from the database. | config.d:475 |
| cleanup_local_files | ignored | Only valid with download_only (refused) | config.d:477 |
| permanent_delete | relevant | Local deletes through the mount (including of online-only files) are permanent online, as in normal mode | config.d:479 |
| disable_upload_hash_streaming | relevant | Uploads | config.d:481 |
| create_new_file_version | relevant | SharePoint enrichment handling. The re-download path goes through downloadFileItem, including the open-file deferral. | config.d:487 |
| force_session_upload | relevant | Uploads | config.d:500 |
| delay_inotify_processing | ignored | Only applies while the inotify monitor is initialised (main.d:1814 `filesystemMonitor.initialised`), which it is not in on-demand mode | config.d:506 |
| inotify_delay | ignored | See delay_inotify_processing | config.d:507 |
| webhook_enabled | relevant | Remote change notification | config.d:510 |
| webhook_public_url, webhook_listening_host, webhook_listening_port, webhook_expiration_interval, webhook_renewal_interval, webhook_retry_interval | relevant | Webhook | config.d:511-516 |
| disable_websocket_support | relevant | Remote change notification | config.d:519 |
| notify_file_actions | relevant | Notifications | config.d:522 |
| notify_monitor_start | relevant | Notification (status text shows "on-demand mount") | config.d:525 |
| display_transfer_metrics | relevant | Engine transfers (not hydrations) | config.d:529 |
| write_xattr_data | relevant | Writes `user.onedrive.createdBy` / `user.onedrive.lastModifiedBy` on backing files after download (sync.d:5388-5389). No clash with the mount's own `user.onedrive.state/pin/action/weburl`. Online-only files have no backing file, so no xattrs. | config.d:534 |
| disable_permission_set | relevant | Backing dir permissions (engine and hydration) | config.d:537 |
| use_intune_sso | relevant | Authentication | config.d:540 |
| use_device_auth | relevant | Authentication | config.d:543 |
| display_manager_integration | relevant | Bookmarks use sync_dir, which is the mountpoint the user sees | config.d:546; main.d:3433 |
| disable_version_check | relevant | Version check | config.d:549 |
| disable_time_check | relevant | System time validation | config.d:553 |
| mirror_local_state | risky | With local_first: online items queued for download are deleted online instead (sync.d:3445-3457), and new online folders are deleted online (sync.d:3918-3922). In on-demand mode new files under pinned folders and changed hydrated files are queued for download, so they would be deleted online, and new online folders too. This contradicts the online-only model. See "Should be refused". | config.d:557 |
| display_memory | relevant | Diagnostics | config.d:597 |
| monitor_max_loop | relevant | Developer option | config.d:601 |
| display_sync_options | relevant | Diagnostics | config.d:604 |
| force_children_scan | relevant | Online scan method | config.d:608 |
| display_processing_time | relevant | Diagnostics | config.d:612 |
| force_xfer_abort | relevant | Engine transfers on exit. Hydrations are aborted by HydrationService.shutdown() regardless. | config.d:614 |

## CLI-only options that matter for a GUI

Set in `updateFromArgs()` (config.d:1308-1337 and getopt); not accepted in the config file:
- `--monitor`: required by on-demand.
- `--on-demand`, `--on-demand-backing-dir`: CLI forms of the config options.
- `--resync` (with `--resync-auth`): required after a mode or backing-dir change.
- `--download`, `--pin`, `--unpin`, `--free`, `--status <path>`: act on a running mount through xattrs only (src/ondemandcli.d). Usable while the monitor runs.
- `--display-config`, `--display-running-config`: show the on-demand options and dbus_status.
- `--sync`: refused with on-demand.
- `--dry-run`: see dry_run.
- `--confdir`: selects the profile and the D-Bus bus name.

## Should be refused but are not

Each would endanger data or leave the client stuck in on-demand mode. Proposed one-line guards for `checkForBasicOptionConflicts()` (config.d, next to the existing on-demand checks), not implemented:
- **mirror_local_state (with local_first)**: deletes online the new files of pinned folders, changed hydrated files and new online folders.
  Guard: `if (getValueBool("on_demand") && getValueBool("mirror_local_state")) { addLogEntry("ERROR: --on-demand cannot be used with --mirror-local-state"); operationalConflictDetected = true; }`
- **dry_run**: the mount and HydrationService change real local data while the engine works on a database copy.
  Guard: `if (getValueBool("on_demand") && getValueBool("dry_run")) { addLogEntry("ERROR: --on-demand cannot be used with --dry-run"); operationalConflictDetected = true; }`
- **recycle_bin_path inside the mountpoint**: passes the existing check (it compares with the backing dir), then every online delete fails to move (EXDEV) and the delta checkpoint is held back forever.
  Guard: in `checkRecycleBinPathAsChildOfSyncDir()` also test `onDemandMountPoint` when `on_demand` is set.

Not proposed for refusal, but documented as risky: bypass_data_preservation (deliberate user choice; upstream semantics) and sync_business_shared_items (shared items simply bypass on-demand).
