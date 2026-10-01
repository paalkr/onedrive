# onedrive-ondemand Debian package

A `.deb` of this fork of the abraunegg/onedrive client with Files On-Demand: the configured `sync_dir` is a FUSE mount, files are downloaded when first opened, and files and folders can be pinned ("always keep on this device") or freed. Built and tested on Ubuntu 24.04 (amd64).

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
- the folder where OneDrive appears (default `~/OneDrive`; it must be empty or not exist yet, because the mount hides what is in it),
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

At the end it offers to run step 2 for you. Running the setup again is safe: an identical profile is left alone, an existing authorisation is reused, and an enabled service is reported. A profile with different settings is only overwritten with `--force` (the old files are kept as `config.bak.N`). Changing `sync_dir` or `sync_list` of a profile that has synchronised needs a `--resync`.

For scripts: `onedrive-ondemand-setup --non-interactive [--profile NAME] [--mount DIR] [--sync-list FOLDER ...] [--application-id GUID] [--azure-tenant-id TENANT] [--use-intune-sso] [--no-auth] [--enable-service] [--force]`. See `--help`.

`on_demand` is not written to the config file: the client refuses `on_demand` without `--monitor`, so it is passed on the command line (`--monitor --on-demand`) by the units.

## Multiple accounts

Each account is a profile directory below `~/.config` with its own mount folder:

```sh
onedrive-ondemand-setup --profile onedrive-ondemand --mount ~/OneDrive
onedrive-ondemand-setup --profile onedrive-ondemand-business --mount ~/OneDrive-Business --business
```

The default profile `onedrive-ondemand` runs as `onedrive-ondemand.service`; every other profile runs as the template instance `onedrive-ondemand@<profile>.service`, e.g. `systemctl --user enable --now onedrive-ondemand@onedrive-ondemand-business.service`. Do not run a profile under both names at once (`onedrive-ondemand@onedrive-ondemand.service` is the same profile as `onedrive-ondemand.service`).

## Logs and troubleshooting

```sh
journalctl --user -u onedrive-ondemand -f
journalctl --user -u onedrive-ondemand@onedrive-ondemand-business -f
```

The service restarts on failure, except when the client exits because a `--resync` is required (exit status 78): stop the service, run the step 1 command, start it again.

When the client stops, the units run `onedrive-ondemand-unmount --confdir=...`, which lazily unmounts (`fusermount3 -u -z`) the profile's `sync_dir` if a stale mount was left behind ("Transport endpoint is not connected"). It can also be run by hand.

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

The package has no maintainer scripts. Removing or purging it never touches user configuration or data: `~/.config/<profile>` (config, tokens, database, backing directory with the downloaded files) and the mount folders stay. Stop the services before removing the package; a running client keeps its mount until it exits. To remove a profile completely, delete `~/.config/<profile>` and its (unmounted, empty) mount folder yourself. Hydrated files and changes that were not uploaded yet live in the backing directory, `~/.config/<profile>/ondemand/backing` by default.
