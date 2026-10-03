# onedrive-ondemand Debian package

A `.deb` of this fork of the abraunegg/onedrive client with Files On-Demand: the configured `sync_dir` is a FUSE mount, files are downloaded when first opened, and files and folders can be pinned ("always keep on this device") or freed. Built and tested on Ubuntu 24.04 (amd64).

## Layout

`sync_dir` is an ordinary directory that holds the downloaded (hydrated) files, and the client mounts the FUSE file system on top of it while it runs. Through the mount you see every file, online-only ones included. When the client is stopped the mount is gone, and `sync_dir` shows only the hydrated files, which stay readable. Online-only files exist only in OneDrive and the client's database.

Profiles from the earlier layout kept the hydrated files in a separate backing directory (`~/.config/<profile>/ondemand/backing`, or `on_demand_backing_dir`). At the first start of this version the client moves that directory into `sync_dir` with `rename()`. Nothing is uploaded, downloaded or deleted. The move needs the same filesystem and an empty or absent `sync_dir`, otherwise the start is refused (see below). `on_demand_backing_dir` is deprecated and only used as the source of that one-time move. Remove it from the config afterwards.

## Build

Build dependencies: `git`, `ldc` (ldc2 >= 1.36), `libcurl4-openssl-dev`, `libsqlite3-dev`, `libdbus-1-dev`, `libfuse3-dev`, `pkg-config`, `dpkg-dev` (for `dpkg-shlibdeps`; without it Depends is derived from `ldd`).

```sh
contrib/ondemand/build-deb.sh -o ~/debs
```

The script copies the working tree (tracked and untracked, not ignored, files) to a temporary directory, runs `./configure DC=ldc2 --prefix=/usr --sysconfdir=/etc ... && make`, stages `make install DESTDIR=...`, adds the on-demand files below, and writes `onedrive-ondemand_<version>_<arch>.deb`. The version comes from `git describe`: `v2.5.11-151-g5a01d01` becomes `2.5.11+ondemand.151.g5a01d01` (`.dirty` appended for uncommitted changes). `-k` keeps the build directory.

Package contents, besides upstream's files (`/usr/bin/onedrive`, man page, docs, completions, icons, logrotate, upstream systemd units):

| Path | Purpose |
|---|---|
| `/usr/bin/onedrive-ondemand-setup` | per-user profile setup (below) |
| `/usr/bin/onedrive-ondemand-unmount` | lazily unmounts a stale mount of a profile's `sync_dir`; used by the units' `ExecStopPost=` |
| `/usr/lib/systemd/user/onedrive-ondemand.service` | runs profile `~/.config/onedrive-ondemand` |
| `/usr/lib/systemd/user/onedrive-ondemand@.service` | runs profile `~/.config/<instance>` |
| `/usr/bin/onedrive-ondemand-resync` | runs a resync of a profile in the background (below) |
| `/usr/lib/systemd/user/onedrive-ondemand-resync@.service` | the resync of profile `~/.config/<instance>`, also for the default profile |
| `/usr/libexec/onedrive-ondemand/resync-unit` | helper of the resync unit |
| `/usr/share/nautilus-python/extensions/onedrive-ondemand.py` | Nautilus state emblems and "OneDrive" context menu |

The package Conflicts/Replaces/Provides `onedrive`: Ubuntu's `onedrive` package ships `/usr/bin/onedrive` too and is removed when this one is installed.

## Install

```sh
sudo apt install ./onedrive-ondemand_*.deb
```

Recommended packages (installed by default by apt): `python3-nautilus` (file manager extension), `libgdk-pixbuf2.0-bin` (`gdk-pixbuf-thumbnailer`, for thumbnails of online-only files), `zenity` (confirmation before freeing up a folder), `libnotify-bin` (error notifications from the extension).

Installing does not enable or start anything. Every user sets up their own profile.

## Per-user setup

```sh
onedrive-ondemand-setup
```

It asks for:

- the profile name (default `onedrive-ondemand`, stored in `~/.config/onedrive-ondemand`),
- the folder where OneDrive appears (default `~/OneDrive`). It may already contain files. They stay visible in the mount and are compared with OneDrive on the first `--resync`, like in a normal synchronisation (for example, files that are not in OneDrive are uploaded). The interactive setup asks for confirmation.
- optionally a list of OneDrive folders to show (written to `sync_list`),
- optionally the work or school account options `application_id`, `azure_tenant_id`, `use_intune_sso`.

It then writes `~/.config/<profile>/config`, runs `onedrive --confdir=...` once so you can sign in, and prints the next commands. It does not run the first synchronisation itself:

```sh
# 1. first synchronisation, in a terminal; Ctrl+C once the initial sync has completed
onedrive --confdir=$HOME/.config/onedrive-ondemand --monitor --on-demand --resync --resync-auth
# 2. from then on in the background, and at every login
systemctl --user daemon-reload
systemctl --user enable --now onedrive-ondemand.service
```

At the end it offers to run step 2 for you. Running the setup again is safe: an identical profile is left alone, an existing authorisation is reused, and an enabled service is reported. A profile with different settings is only overwritten with `--force` (the old files are kept as `config.bak.N`). Changing `sync_list` of a profile that has synchronised needs a `--resync`. Changing `sync_dir` moves the folder at the next start when the new path is on the same filesystem and empty or absent; otherwise the start is refused and a `--resync` is needed.

For scripts: `onedrive-ondemand-setup --non-interactive [--profile NAME] [--mount DIR] [--sync-list FOLDER ...] [--application-id GUID] [--azure-tenant-id TENANT] [--use-intune-sso] [--no-auth] [--enable-service] [--force]`. See `--help`.

`on_demand` is not written to the config file: the client refuses `on_demand` without `--monitor`, so it is passed on the command line (`--monitor --on-demand`) by the units.

## Multiple accounts

Each account is a profile directory below `~/.config` with its own mount folder:

```sh
onedrive-ondemand-setup --profile onedrive-ondemand --mount ~/OneDrive
onedrive-ondemand-setup --profile onedrive-ondemand-business --mount ~/OneDrive-Business --business
```

The default profile `onedrive-ondemand` runs as `onedrive-ondemand.service`; every other profile runs as the template instance `onedrive-ondemand@<profile>.service`, e.g. `systemctl --user enable --now onedrive-ondemand@onedrive-ondemand-business.service`. Do not run a profile under both names at once (`onedrive-ondemand@onedrive-ondemand.service` is the same profile as `onedrive-ondemand.service`).

## Resync

When the client asks for a `--resync` (the service stops with exit status 78), or after changing `sync_list` (or a `sync_dir` change that could not be moved):

```sh
onedrive-ondemand-resync                              # default profile onedrive-ondemand
onedrive-ondemand-resync onedrive-ondemand-business   # any other profile
onedrive-ondemand-resync --no-follow PROFILE          # start it and return
```

This starts the user unit `onedrive-ondemand-resync@<profile>.service` (the instance is always the profile directory name, also `onedrive-ondemand-resync@onedrive-ondemand.service` for the default profile). The unit:

1. stops the profile's normal unit (`onedrive-ondemand.service` for the default profile, `onedrive-ondemand@<profile>.service` otherwise) and marks the profile as resyncing (`$XDG_RUNTIME_DIR/onedrive-ondemand/<profile>.resyncing`; while it exists the normal unit is skipped if anything starts it),
2. runs `onedrive --on-demand --on-demand-resync-once --confdir=~/.config/<profile>`: resync, first full sync and restore of pins, with the mount active,
3. on success starts the normal unit again; on failure stays in the failed state (`systemctl --user status onedrive-ondemand-resync@<profile>`) and leaves the normal unit stopped.

The command follows the unit's journal until it finishes and exits with the resync's status. Ctrl+C only stops following. `systemctl --user stop onedrive-ondemand-resync@<profile>` cancels a resync (the normal unit then stays stopped). After a failed or cancelled resync the normal unit can be started by hand (`systemctl --user start onedrive-ondemand.service` or `onedrive-ondemand@<profile>.service`): it rebuilds the index on its first cycle and re-applies the recorded pins. The resync client exits 0 on success and 1 on any failure (no stored sign-in, authentication failure, invalid configuration, OneDrive unreachable, stopped before completion); individual file failures do not count as failure.

## Logs and troubleshooting

```sh
journalctl --user -u onedrive-ondemand -f
journalctl --user -u onedrive-ondemand@onedrive-ondemand-business -f
```

The service restarts on failure, except when the client exits because a `--resync` is required (exit status 78): run `onedrive-ondemand-resync [<profile>]` (see Resync), or stop the service, run the step 1 command by hand and start it again.

Resync logs: `journalctl --user -u onedrive-ondemand-resync@<profile>`.

When the client stops, the units run `onedrive-ondemand-unmount --confdir=...`, which lazily unmounts (`fusermount3 -u -z`) the profile's `sync_dir` if a stale mount was left behind ("Transport endpoint is not connected"). After a clean stop it does nothing. The client also unmounts a stale mount itself when it starts, and the files in `sync_dir` underneath are never touched. It can also be run by hand.

The client refuses to start in these cases. The messages are in the journal:

| Message contains | Meaning | What to do |
|---|---|---|
| `already mounted by a running on-demand client` | another client (a second unit, or a foreground run) has `sync_dir` mounted | stop that client, or if none is running, `fusermount3 -u -z <sync_dir>` |
| `does not respond` | the mount on `sync_dir` belongs to a hung client | stop or kill that client, or `fusermount3 -u -z <sync_dir>` |
| `already contains files` | the old backing directory or the previous `sync_dir` should be moved into `sync_dir`, but `sync_dir` is not empty | move the files yourself (never overwrite), or run a resync |
| `same filesystem` | that move failed, typically because the source and `sync_dir` are on different filesystems | move the files yourself, or run a resync |

The units deliberately have no sandboxing options: a mount namespace (`ProtectSystem=`, `PrivateTmp=`, ...) would hide the mount from the desktop session, and `NoNewPrivileges=` (implied by `RestrictRealtime=`, `SystemCallFilter=`, ...) breaks the setuid `fusermount3`.

## Nautilus

The extension is loaded when Nautilus starts. After installing (or upgrading) the package, restart it:

```sh
nautilus -q
```

## Uninstall

```sh
systemctl --user disable --now onedrive-ondemand.service   # and any onedrive-ondemand@<profile>.service
sudo apt remove onedrive-ondemand
```

The package has no maintainer scripts. Removing or purging it never touches user configuration or data: `~/.config/<profile>` (config, tokens, database) and the `sync_dir` folders with the downloaded files stay. Stop the services before removing the package; a running client keeps its mount until it exits. Afterwards each `sync_dir` is an ordinary folder with the hydrated files, including changes that were not uploaded yet. To remove a profile completely, delete `~/.config/<profile>` and its `sync_dir` yourself, after checking that nothing in it still needs uploading.
