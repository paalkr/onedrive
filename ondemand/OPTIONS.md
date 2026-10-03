# Config options in on-demand mode

Every option the config file accepts: the keys with defaults in `ApplicationConfig.initialise()` (src/config.d:317-614); the config file parser (src/config.d:1004-1110) accepts exactly those keys. Line numbers are against `ondemand/main` at 8f3c350.

On-demand facts used below:
- `sync_dir` is both the physical directory that holds hydrated files and the FUSE mountpoint on top of it. The engine reaches the physical tree through a directory fd opened before the mount (`runtimeSyncDirectory` is `sync_dir`; the working directory stays the physical directory).
- inotify is not started (main.d `!download_only && !on_demand` around the monitor initialisation). Local changes come from the FUSE layer.
- The mount reports an online-only file as `S_IFREG|0600` and a directory known only to the database as `S_IFDIR|0700`. Anything present in the physical sync_dir gets the `lstat` of the physical file (src/ondemand.d:90-91, 503-506, 628-636). It mounts with `default_permissions` (src/ondemand.d:761).
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
| skip_dir (R) | relevant | Client-side filtering. Excluded online items are not recorded, so they do not appear in the mount. A matching folder created through the mount stays local only (in the physical sync_dir). | config.d:319, 1081 |
| skip_file (R) | relevant | As skip_dir, for files | config.d:320, 1074 |
| sync_dir (R in normal mode only) | relevant-ondemand | The physical directory that holds hydrated files, with the FUSE mount on top. Changing it in on-demand mode moves the physical directory to the new path with rename() (same filesystem, new path absent or empty), so no --resync is needed; otherwise the start is refused and --resync is required. A stale on-demand mount on it is unmounted at start. | config.d:321, 1064; main.d prepareOnDemandPhysicalSyncDir |
| user_agent | relevant | HTTP | config.d:322; onedrive.d:280 |
| drive_id (R) | relevant | SharePoint library selection | config.d:324 |
| azure_ad_endpoint | relevant | National cloud endpoints | config.d:340 |
| azure_tenant_id | relevant | Authentication | config.d:342 |
| transfer_order | relevant | Order of engine download/upload batches. Hydrations are on demand and not ordered. | config.d:350 |
| monitor_authoritative_sync | ignored | Only consulted with download_only + cleanup_local_files, which on-demand refuses | config.d:354; main.d:1572; sync.d:1181 |
| use_recycle_bin | risky | Online deletions move hydrated files from the physical sync_dir to the recycle bin (online-only files have no local file, so nothing moves). A recycle_bin_path inside sync_dir is refused at startup (config.d checkRecycleBinPathAsChildOfSyncDir, main.d recycle bin check). A rename cannot reach a recycle bin inside the mount (different filesystem). | config.d:358 |
| recycle_bin_path | risky | Refused inside sync_dir; otherwise see use_recycle_bin | config.d:360 |
| verbose | relevant | Logging | config.d:363 |
| monitor_interval | relevant | Sync cycle interval. Also the long interval of locked-online retries. | config.d:365 |
| skip_size (R) | relevant | Filtering. Larger online files are not recorded, so they are not visible in the mount. | config.d:367 |
| monitor_log_frequency | relevant | Log suppression | config.d:369 |
| monitor_fullscan_frequency | relevant | Online full-scan true-up | config.d:373 |
| classify_as_big_delete | relevant | Applies in uploadDeletedItem (sync.d:12768). `rm -r` through the mount emits one delete per file (like inotify), so it rarely triggers, as in normal monitor mode. Absent hydrated files found by the consistency check are counted as usual. Online-only files are never counted as deleted. | config.d:375 |
| sync_dir_permissions | relevant | Applied to folders the engine creates in the physical sync_dir. Visible through the mount for folders present there. Database-only folders show 0700. | config.d:377; ondemand.d:503-506, 628-630 |
| sync_file_permissions | relevant | Applied to downloaded/hydrated files and visible through the mount (lstat). Online-only files always show 0600. | config.d:379; hydration.d (filePermissions); ondemand.d:631-632 |
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
| check_nomount | ignored | Checks for `.nosync` in the working directory, which is the physical sync_dir (checked before the mount and through the directory opened before it), so it detects an unmounted sync_dir disk as in normal mode. | config.d:411; main.d:2820 |
| check_nosync (R) | relevant | `.nosync` in a folder of sync_dir (created through the mount) protects it as in normal mode | config.d:413; sync.d:2612, 2948, 7439 |
| download_only | refused | See upload_only | config.d:415 |
| on_demand | relevant-ondemand | Requires --monitor. Database marker checks (main.d checkOnDemandProfileState). | config.d:417 |
| on_demand_backing_dir | ignored | Deprecated since the physical sync_dir layout: hydrated files are kept in sync_dir under the mount. Only used once, with a warning, as the source of moving an old backing directory into sync_dir (main.d prepareOnDemandPhysicalSyncDir). | config.d:419 |
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
| skip_symlinks (R) | ignored | Symlinks cannot be created through the mount (no symlink operation). Only writes into the physical sync_dir while the client is stopped could create one, and those are unsupported. | config.d:448; sync.d:7557, 9946 |
| debug_https | relevant | Diagnostics. Pre-signed thumbnail URLs are redacted (curlEngine.d redactUrlValues). | config.d:450 |
| skip_dotfiles (R) | relevant | Filtering | config.d:452 |
| dry_run | refused | "--on-demand cannot be used with --dry-run" (config.d checkForBasicOptionConflicts). A dry run fakes engine transfers on a database copy while the mount and HydrationService would change real local data. | config.d:454; main.d:510 |
| sync_root_files | relevant | sync_list | config.d:456 |
| remove_source_files | ignored | Only valid with upload_only (refused) | config.d:458 |
| remove_source_folders | ignored | Only valid with upload_only (refused) | config.d:460 |
| skip_dir_strict_match | relevant | Filtering | config.d:462 |
| resync | relevant | Rebuilds the database. Required after switching modes, or after a sync_dir change that cannot be done by rename() (main.d checkOnDemandProfileState, prepareOnDemandPhysicalSyncDir). | config.d:464 |
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
| write_xattr_data | relevant | Writes `user.onedrive.createdBy` / `user.onedrive.lastModifiedBy` on hydrated files after download (sync.d:5388-5389). No clash with the mount's own `user.onedrive.state/pin/action/weburl`. Online-only files have no physical file, so no xattrs. | config.d:534 |
| disable_permission_set | relevant | Backing dir permissions (engine and hydration) | config.d:537 |
| use_intune_sso | relevant | Authentication | config.d:540 |
| use_device_auth | relevant | Authentication | config.d:543 |
| display_manager_integration | relevant | Bookmarks use sync_dir, which is the mountpoint the user sees | config.d:546; main.d:3433 |
| disable_version_check | relevant | Version check | config.d:549 |
| disable_time_check | relevant | System time validation | config.d:553 |
| mirror_local_state | refused | "--on-demand cannot be used with --mirror-local-state" (config.d checkForBasicOptionConflicts). With local_first it deletes online what is queued for download (sync.d:3445-3457) and new online folders (sync.d:3918-3922), which contradicts online-only files. | config.d:557 |
| display_memory | relevant | Diagnostics | config.d:597 |
| monitor_max_loop | relevant | Developer option | config.d:601 |
| display_sync_options | relevant | Diagnostics | config.d:604 |
| force_children_scan | relevant | Online scan method | config.d:608 |
| display_processing_time | relevant | Diagnostics | config.d:612 |
| force_xfer_abort | relevant | Engine transfers on exit. Hydrations are aborted by HydrationService.shutdown() regardless. | config.d:614 |

## Machine-readable summary

One row per config key, for tools (OneDriveGUI's settings editor parses this table). Class is the on-demand status from the table above; Resync is `yes` when changing the option requires `--resync`.

| Option | Class | Resync | Notes |
|---|---|---|---|
| `application_id` | relevant | no | Authentication only. |
| `log_dir` | relevant | no | Logging only. |
| `skip_dir` | relevant | yes | Client-side filtering. |
| `skip_file` | relevant | yes | As skip_dir, for files. |
| `sync_dir` | relevant-ondemand | no | Holds the hydrated files with the mount on top; changing it moves the folder (same filesystem), otherwise --resync is required. |
| `user_agent` | relevant | no | HTTP. |
| `drive_id` | relevant | yes | SharePoint library selection. |
| `azure_ad_endpoint` | relevant | no | National cloud endpoints. |
| `azure_tenant_id` | relevant | no | Authentication. |
| `transfer_order` | relevant | no | Order of engine download/upload batches. |
| `monitor_authoritative_sync` | ignored | no | Only consulted with download_only + cleanup_local_files, which on-demand refuses. |
| `use_recycle_bin` | risky | no | Online deletions move local files to the recycle bin; a recycle bin inside sync_dir is refused. |
| `recycle_bin_path` | risky | no | Refused inside sync_dir. |
| `verbose` | relevant | no | Logging. |
| `monitor_interval` | relevant | no | Sync cycle interval. |
| `skip_size` | relevant | yes | Filtering. |
| `monitor_log_frequency` | relevant | no | Log suppression. |
| `monitor_fullscan_frequency` | relevant | no | Online full-scan true-up. |
| `classify_as_big_delete` | relevant | no | Applies in uploadDeletedItem (sync.d:12768). |
| `sync_dir_permissions` | relevant | no | Applied to folders the engine creates in sync_dir. |
| `sync_file_permissions` | relevant | no | Applied to downloaded/hydrated files and visible through the mount (lstat). |
| `rate_limit` | relevant | no | Applies to engine transfers and hydrations (same CurlEngine). |
| `space_reservation` | relevant | no | Download and hydration free-space check. |
| `file_fragment_size` | relevant | no | Session uploads. |
| `operation_timeout` | relevant | no | HTTP. |
| `dns_timeout` | relevant | no | HTTP, connectivity probe. |
| `connect_timeout` | relevant | no | HTTP, connectivity probe, thumbnails. |
| `data_timeout` | relevant | no | HTTP, thumbnails. |
| `ip_protocol_version` | relevant | no | HTTP. |
| `max_curl_idle` | relevant | no | CurlEngine pool. |
| `threads` | relevant | no | Engine transfer pool. |
| `upload_only` | refused | no | "--on-demand cannot be used with --upload-only or --download-only". |
| `check_nomount` | ignored | no | Checks for `.nosync` in the physical sync_dir, as in normal mode. |
| `check_nosync` | relevant | yes | `.nosync` in a folder of sync_dir (created through the mount) protects it as in normal mode. |
| `download_only` | refused | no | See upload_only. |
| `on_demand` | relevant-ondemand | no | Requires --monitor. |
| `on_demand_backing_dir` | ignored | no | Deprecated: hydrated files are kept in sync_dir; only used once to move an old backing directory into sync_dir. |
| `dbus_status` | relevant-ondemand | no | D-Bus status interface, both modes. |
| `on_demand_thumbnails` | relevant-ondemand | no | Thumbnails for online-only files. |
| `on_demand_cli_download` | refused | no | CLI only. |
| `on_demand_cli_pin` | refused | no | CLI only. |
| `on_demand_cli_unpin` | refused | no | CLI only. |
| `on_demand_cli_free` | refused | no | CLI only. |
| `on_demand_cli_status` | refused | no | CLI only. |
| `disable_notifications` | relevant | no | Desktop notifications. |
| `disable_download_validation` | relevant | no | Honoured by engine downloads and hydrations (hydration.d verifyDownload). |
| `disable_upload_validation` | relevant | no | Uploads. |
| `enable_logging` | relevant | no | Logging. |
| `force_http_11` | relevant | no | HTTP. |
| `local_first` | relevant | no | Local-first ordering of the standard sync (main.d:2125). |
| `no_remote_delete` | ignored | no | Only valid with upload_only, which on-demand refuses (config.d "--no-remote-delete can only be used with --upload-only"). |
| `skip_symlinks` | ignored | yes | Symlinks cannot be created through the mount (no symlink operation). |
| `debug_https` | relevant | no | Diagnostics. |
| `skip_dotfiles` | relevant | yes | Filtering. |
| `dry_run` | refused | no | Refused with --on-demand: a dry run would fake engine transfers while the mount changes real local data. |
| `sync_root_files` | relevant | no | sync_list. |
| `remove_source_files` | ignored | no | Only valid with upload_only (refused). |
| `remove_source_folders` | ignored | no | Only valid with upload_only (refused). |
| `skip_dir_strict_match` | relevant | no | Filtering. |
| `resync` | relevant | no | Rebuilds the database. |
| `resync_auth` | relevant | no | Authentication. |
| `bypass_data_preservation` | risky | no | No safeBackup conflict copies. |
| `sync_business_shared_items` | risky | yes | Shared (remote) items are out of scope for on-demand. |
| `display_running_config` | relevant | no | Display. |
| `read_only_auth_scope` | relevant | no | Uploads fail; local edits through the mount stay local. |
| `cleanup_local_files` | ignored | no | Only valid with download_only (refused). |
| `permanent_delete` | relevant | no | Local deletes through the mount (including of online-only files) are permanent online, as in normal mode. |
| `disable_upload_hash_streaming` | relevant | no | Uploads. |
| `create_new_file_version` | relevant | no | SharePoint enrichment handling. |
| `force_session_upload` | relevant | no | Uploads. |
| `delay_inotify_processing` | ignored | no | Only applies while the inotify monitor is initialised (main.d:1814 `filesystemMonitor.initialised`), which it is not in on-demand mode. |
| `inotify_delay` | ignored | no | See delay_inotify_processing. |
| `webhook_enabled` | relevant | no | Remote change notification. |
| `webhook_public_url` | relevant | no | Webhook. |
| `webhook_listening_host` | relevant | no | Webhook. |
| `webhook_listening_port` | relevant | no | Webhook. |
| `webhook_expiration_interval` | relevant | no | Webhook. |
| `webhook_renewal_interval` | relevant | no | Webhook. |
| `webhook_retry_interval` | relevant | no | Webhook. |
| `disable_websocket_support` | relevant | no | Remote change notification. |
| `notify_file_actions` | relevant | no | Notifications. |
| `notify_monitor_start` | relevant | no | Notification (status text shows "on-demand mount"). |
| `display_transfer_metrics` | relevant | no | Engine transfers (not hydrations). |
| `write_xattr_data` | relevant | no | Writes `user.onedrive.createdBy` / `user.onedrive.lastModifiedBy` on hydrated files after download (sync.d:5388-5389). |
| `disable_permission_set` | relevant | no | Backing dir permissions (engine and hydration). |
| `use_intune_sso` | relevant | no | Authentication. |
| `use_device_auth` | relevant | no | Authentication. |
| `display_manager_integration` | relevant | no | Bookmarks use sync_dir, which is the mountpoint the user sees. |
| `disable_version_check` | relevant | no | Version check. |
| `disable_time_check` | relevant | no | System time validation. |
| `mirror_local_state` | refused | no | Refused with --on-demand: with local_first it would delete online files and folders that are online-only here. |
| `display_memory` | relevant | no | Diagnostics. |
| `monitor_max_loop` | relevant | no | Developer option. |
| `display_sync_options` | relevant | no | Diagnostics. |
| `force_children_scan` | relevant | no | Online scan method. |
| `display_processing_time` | relevant | no | Diagnostics. |
| `force_xfer_abort` | relevant | no | Engine transfers on exit. |

## CLI-only options that matter for a GUI

Set in `updateFromArgs()` (config.d:1308-1337 and getopt); not accepted in the config file:
- `--monitor`: required by on-demand.
- `--on-demand`, `--on-demand-backing-dir`: CLI forms of the config options (`--on-demand-backing-dir` is deprecated like the option).
- `--resync` (with `--resync-auth`): required after a mode change, or a sync_dir change that cannot be done by rename().
- `--on-demand-resync-once` (with `--on-demand --confdir X`): one-shot rebuild for helpers and GUIs. It implies `--monitor --resync --resync-auth` (no confirmation prompt) and starts like the monitor (mount, D-Bus State `syncing`, StateDetail "Rebuilding the local index"). It runs the first full sync cycle, re-applies pins and waits up to 10 minutes for the pin actions, then shuts down cleanly. Exit 0 when that completed (item-level sync failures do not count). Exit 1 when:
  - `--on-demand` is missing;
  - no stored authentication (it never prompts);
  - an authentication failure or refused configuration;
  - Microsoft OneDrive is unreachable or the system time is unsafe at the first cycle;
  - SIGTERM/SIGINT before completion.

  Ignored with a warning in the config file.
- `--download`, `--pin`, `--unpin`, `--free`, `--status <path>`: act on a running mount through xattrs only (src/ondemandcli.d). Usable while the monitor runs.
- `--display-config`, `--display-running-config`: show the on-demand options and dbus_status.
- `--sync`: refused with on-demand.
- `--dry-run`: see dry_run.
- `--confdir`: selects the profile and the D-Bus bus name.

## Refusal guards added

The three combinations previously listed here as "should be refused" are now refused at startup (on-demand mode only; normal mode is unchanged):
- on_demand with mirror_local_state: `ERROR: --on-demand cannot be used with --mirror-local-state`
- on_demand with dry_run: `ERROR: --on-demand cannot be used with --dry-run`
- on_demand with a recycle_bin_path inside the mountpoint: `ERROR: The configured 'recycle_bin_path' (...) is located within the configured 'sync_dir' (<mountpoint>).`

Documented as risky, not refused: bypass_data_preservation (a deliberate user choice; upstream semantics) and sync_business_shared_items (shared items bypass on-demand).
