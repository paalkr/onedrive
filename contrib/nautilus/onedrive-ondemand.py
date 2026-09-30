# OneDrive Files On-Demand integration for GNOME Files (Nautilus 43+).
#
# Shows the on-demand state of files and folders inside an onedrive
# on-demand mount (fstype fuse.onedrive) and adds a "OneDrive" submenu to
# the context menu: View online, Download now, Always keep on this device /
# Stop keeping on this device, Free up space.
#
# Everything goes through extended attributes on the mount path
# (user.onedrive.state to read, user.onedrive.action to act). The extension
# never opens or reads file contents inside the mount, because that would
# download online-only files.
#
# Requirements: nautilus-python 4.0 (Debian/Ubuntu package python3-nautilus),
# optionally notify-send (libnotify-bin) for error notifications.
#
# Install for the current user:
#
#   mkdir -p ~/.local/share/nautilus-python/extensions
#   cp onedrive-ondemand.py ~/.local/share/nautilus-python/extensions/
#   nautilus -q
#
# Nautilus loads the extension the next time it starts. To debug, run
# `nautilus` from a terminal; errors from this extension go to stderr.
#
# State indication:
#   - Emblems (grid and list view). Nautilus 46 draws extension emblems in
#     both NautilusGridCell and NautilusNameCell, provided the icon exists in
#     the icon theme.
#   - A "OneDrive" column for list view (enable it via the view options,
#     "Visible Columns").
#   The mount root shows no state: its state is a walk of the whole drive.
#   Folder states are read asynchronously and appear shortly after the folder.
#
# Freeing up space in a folder asks for confirmation first (zenity; without
# zenity it is refused). The mount root only offers "Download now".

import os
import re
import shutil
import sys
from collections import OrderedDict

import gi

gi.require_version("Nautilus", "4.0")
from gi.repository import GLib, GObject, Gio, Nautilus  # noqa: E402

MOUNTS_FILE = "/proc/self/mounts"
FSTYPE = "fuse.onedrive"
STATE_XATTR = "user.onedrive.state"
# GIO spelling of user.onedrive.action, used for async writes.
ACTION_GIO_ATTR = "xattr::onedrive.action"
STATE_GIO_ATTR = "xattr::onedrive.state"
WEBURL_GIO_ATTR = "xattr::onedrive.weburl"
STATE_ATTRIBUTE = "onedrive_state"

MOUNT_CACHE_SECONDS = 2.0
REFRESH_SECONDS = 5
# Items in a transient state are re-read this often until they settle.
TRANSIENT_REFRESH_SECONDS = 2
TRANSIENT_STATES = ("syncing", "pending")
# A folder's state is a subtree walk in the client; do not re-query a folder
# more often than this when Nautilus asks again (e.g. after an invalidate).
DIR_QUERY_MIN_SECONDS = 1.0
MAX_TRACKED = 500

EMBLEMS = {
    "online-only": "weather-overcast-symbolic",
    "hydrated": "emblem-ok-symbolic",
    "pinned": "emblem-default-symbolic",
    "local": "emblem-synchronizing-symbolic",
    "syncing": "emblem-synchronizing-symbolic",
    "pending": "emblem-synchronizing-symbolic",
    "error": "dialog-error-symbolic",
}

# Column text, in the Windows client's wording where it has one.
LABELS = {
    "online-only": "Available when online",
    "hydrated": "Available on this device",
    "pinned": "Always available on this device",
    "local": "Not uploaded yet",
    "syncing": "Syncing",
    "pending": "Waiting to sync",
    "error": "Sync error",
}


def log(msg):
    print("onedrive-ondemand: " + msg, file=sys.stderr, flush=True)


def _unescape_mount_field(field):
    # /proc/mounts escapes space, tab, newline and backslash as octal.
    out = []
    i = 0
    while i < len(field):
        if field[i] == "\\" and field[i + 1:i + 4].isdigit() and len(field[i + 1:i + 4]) == 3:
            out.append(chr(int(field[i + 1:i + 4], 8)))
            i += 4
        else:
            out.append(field[i])
            i += 1
    return "".join(out)


class MountTable:
    """Mount points from /proc/self/mounts, cached for a couple of seconds."""

    def __init__(self, path=MOUNTS_FILE, clock=GLib.get_monotonic_time):
        self.path = path
        self.clock = clock
        self.stamp = None
        self.mounts = []  # (mountpoint, fstype), longest first

    def _load(self):
        mounts = []
        try:
            with open(self.path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 3:
                        mounts.append((_unescape_mount_field(parts[1]), parts[2]))
        except OSError as e:
            log("cannot read %s: %s" % (self.path, e))
        mounts.sort(key=lambda m: len(m[0]), reverse=True)
        return mounts

    def _current(self):
        now = self.clock()
        if self.stamp is None or now - self.stamp > MOUNT_CACHE_SECONDS * 1e6:
            self.mounts = self._load()
            self.stamp = now
        return self.mounts

    def ondemand_mount_for(self, path):
        """Mount point of the on-demand mount containing path, or None."""
        if not path:
            return None
        for mountpoint, fstype in self._current():
            root = mountpoint.rstrip("/") or "/"
            if path == root or path.startswith(root.rstrip("/") + "/"):
                # The innermost mount decides; a foreign mount nested inside
                # the on-demand mount is not ours.
                return mountpoint if fstype == FSTYPE else None
        return None


def read_state(path):
    """user.onedrive.state of path, or None. Only getxattr, never open."""
    try:
        return os.getxattr(path, STATE_XATTR).decode("utf-8", "replace").strip()
    except OSError:
        return None


def describe_error(action, err):
    def is_(code):
        return isinstance(err, GLib.Error) and err.matches(Gio.io_error_quark(), code)

    if is_(Gio.IOErrorEnum.BUSY):
        if action == "free":
            return ("Cannot free up space: the item is kept on this device, has local "
                    "changes that are not uploaded yet, or does not match OneDrive.")
        return "OneDrive is busy with this item. Try again later."
    if is_(Gio.IOErrorEnum.WOULD_BLOCK):
        return "OneDrive is busy. Try again in a moment."
    if is_(Gio.IOErrorEnum.NOT_SUPPORTED):
        return "This OneDrive client does not support this action."
    if is_(Gio.IOErrorEnum.NOT_CONNECTED):
        return "The OneDrive mount is not active."
    return err.message if isinstance(err, GLib.Error) else str(err)


def notify(title, body):
    """Desktop notification via notify-send, else stderr. Never raises."""
    log("%s: %s" % (title, body))
    exe = shutil.which("notify-send")
    if not exe:
        return
    try:
        # Without DO_NOT_REAP_CHILD, GLib reaps the child itself.
        GLib.spawn_async([exe, "--app-name=OneDrive", "--icon=dialog-error", title, body],
                         flags=GLib.SpawnFlags.DEFAULT)
    except GLib.Error as e:
        log("notify-send failed: %s" % e.message)


def confirm_with_zenity(title, text, ok_label, callback, program="zenity"):
    """Ask a yes/no question without blocking Nautilus; callback(bool).
    No zenity, or any failure, counts as "no"."""
    exe = shutil.which(program)
    if not exe:
        log("%s not found, refusing '%s' without confirmation" % (program, title))
        callback(False)
        return

    def done(proc, result):
        try:
            ok = proc.wait_check_finish(result)
        except GLib.Error:
            ok = False  # Cancel, window closed, or zenity failed
        callback(ok)

    try:
        proc = Gio.Subprocess.new([exe, "--question", "--title=" + title, "--text=" + text,
                                   "--ok-label=" + ok_label, "--cancel-label=Cancel"],
                                  Gio.SubprocessFlags.NONE)
        proc.wait_check_async(None, done)
    except GLib.Error as e:
        log("%s failed: %s" % (program, e.message))
        callback(False)


def launch_uri(uri, callback, data):
    """Open uri with the default handler without blocking; callback(error
    message or None, data)."""
    def done(_source, result):
        try:
            Gio.AppInfo.launch_default_for_uri_finish(result)
            callback(None, data)
        except GLib.Error as e:
            callback(e.message, data)

    Gio.AppInfo.launch_default_for_uri_async(uri, None, None, done)


def unescape_gio_string(value):
    """GIO escapes backslashes and non-printable bytes in xattr strings as \\xNN."""
    raw = re.sub(rb"\\x([0-9a-fA-F]{2})", lambda m: bytes([int(m.group(1), 16)]),
                 value.encode("utf-8"))
    return raw.decode("utf-8", "replace")


ACTION_TITLES = {
    "view": "View online",
    "download": "Download now",
    "pin": "Always keep on this device",
    "unpin": "Stop keeping on this device",
    "free": "Free up space",
}


class OneDriveOnDemandExtension(GObject.GObject,
                                Nautilus.InfoProvider,
                                Nautilus.MenuProvider,
                                Nautilus.ColumnProvider):

    def __init__(self, mounts=None, notifier=notify, confirmer=confirm_with_zenity,
                 launcher=None):
        super().__init__()
        self.launcher = launcher or launch_uri
        self.mounts = mounts or MountTable()
        self.notifier = notifier
        self.confirmer = confirmer
        # uri -> (FileInfo, path, state) of files Nautilus showed us, most
        # recent last, for the periodic refresh. For folders the state is
        # the last value read asynchronously.
        self.tracked = OrderedDict()
        self.refresh_source = None
        self.transient_source = None
        self.pending = set()  # uris with a state query in flight
        self.fetched = {}  # uri -> monotonic time of the last async read

    # ---- helpers ---------------------------------------------------------

    def _path_in_mount(self, file):
        """(path, is_mount_root) for a file inside an on-demand mount, else None."""
        try:
            if file.get_uri_scheme() != "file":
                return None
            path = file.get_location().get_path()
        except Exception:
            return None
        mountpoint = self.mounts.ondemand_mount_for(path) if path else None
        if mountpoint is None:
            return None
        return path, path.rstrip("/") == mountpoint.rstrip("/")

    def _track(self, file, path, state):
        uri = file.get_uri()
        self.tracked[uri] = (file, path, state)
        self.tracked.move_to_end(uri)
        while len(self.tracked) > MAX_TRACKED:
            self.tracked.popitem(last=False)
        if self.refresh_source is None:
            self.refresh_source = GLib.timeout_add_seconds(REFRESH_SECONDS, self._refresh)
        self._watch_transient(state)

    def _watch_transient(self, state):
        if state in TRANSIENT_STATES and self.transient_source is None:
            self.transient_source = GLib.timeout_add_seconds(TRANSIENT_REFRESH_SECONDS,
                                                             self._refresh_transient)

    def _refresh_transient(self):
        """Re-read syncing/pending items; stops once none are left."""
        busy = False
        for uri, (file, path, state) in list(self.tracked.items()):
            if state in TRANSIENT_STATES and not file.is_gone():
                busy = True
                self._query_async(uri, path)
        if not busy:
            self.transient_source = None
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    def _refresh(self):
        """Re-read the state of tracked files asynchronously (getxattr in a
        GIO worker thread) and invalidate the ones that changed."""
        for uri, (file, path, state) in list(self.tracked.items()):
            if file.is_gone():
                del self.tracked[uri]
                self.fetched.pop(uri, None)
                continue
            self._query_async(uri, path)
        if not self.tracked:
            self.refresh_source = None
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    def _query_async(self, uri, path):
        if uri in self.pending:
            return
        self.pending.add(uri)
        Gio.File.new_for_path(path).query_info_async(
            STATE_GIO_ATTR, Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_LOW, None,
            self._refresh_done, uri)

    def _refresh_done(self, gfile, result, uri):
        self.pending.discard(uri)
        self.fetched[uri] = GLib.get_monotonic_time()
        try:
            info = gfile.query_info_finish(result)
            new_state = info.get_attribute_as_string(STATE_GIO_ATTR)
        except GLib.Error:
            new_state = None
        except Exception as e:  # never raise inside Nautilus
            log("refresh failed: %s" % e)
            return
        entry = self.tracked.get(uri)
        if entry is None:
            return
        file, path, state = entry
        if new_state is not None:
            new_state = new_state.strip()
        if new_state != state:
            self.tracked[uri] = (file, path, new_state)
            self._watch_transient(new_state)
            file.invalidate_extension_info()

    # ---- InfoProvider ----------------------------------------------------

    def update_file_info(self, file):
        try:
            found = self._path_in_mount(file)
            if found is None:
                return Nautilus.OperationResult.COMPLETE
            path, is_root = found
            if is_root:
                # The root's state is a walk of the whole drive; not shown.
                return Nautilus.OperationResult.COMPLETE
            if file.is_directory():
                state = self._dir_state(file, path)
            else:
                state = read_state(path)
            if state in EMBLEMS:
                file.add_emblem(EMBLEMS[state])
            file.add_string_attribute(STATE_ATTRIBUTE, LABELS.get(state, state or ""))
            self._track(file, path, state)
        except Exception as e:
            log("update_file_info failed: %s" % e)
        return Nautilus.OperationResult.COMPLETE

    def _dir_state(self, file, path):
        """Last known state of a folder, never read on the main thread.

        update_file_info_full is not used: nautilus-python 4.0 passes
        Nautilus' uninitialised handle through unchanged, so a pending
        request cannot be told apart from others on cancel_update. Instead
        the folder is queried with async GIO and, when the answer differs
        from what is shown, invalidated so Nautilus asks again and gets the
        cached value."""
        uri = file.get_uri()
        entry = self.tracked.get(uri)
        state = entry[2] if entry else None
        last = self.fetched.get(uri)
        if last is None or GLib.get_monotonic_time() - last > DIR_QUERY_MIN_SECONDS * 1e6:
            self._query_async(uri, path)
        return state

    def _known_state(self, file, path):
        if file.is_directory():
            entry = self.tracked.get(file.get_uri())
            return entry[2] if entry else None
        return read_state(path)

    # ---- ColumnProvider --------------------------------------------------

    def get_columns(self):
        return [Nautilus.Column(name="OneDriveOnDemand::state_column",
                                attribute=STATE_ATTRIBUTE,
                                label="OneDrive",
                                description="OneDrive Files On-Demand state")]

    # ---- MenuProvider ----------------------------------------------------

    def get_file_items(self, files):
        try:
            return self._menu_for(files)
        except Exception as e:
            log("get_file_items failed: %s" % e)
            return []

    def get_background_items(self, current_folder):
        try:
            return self._menu_for([current_folder], name_prefix="OneDriveOnDemand::bg")
        except Exception as e:
            log("get_background_items failed: %s" % e)
            return []

    def _menu_for(self, files, name_prefix="OneDriveOnDemand"):
        targets = []
        any_root = False
        for file in files:
            found = self._path_in_mount(file)
            if found is None:
                # Mixed selections (inside and outside a mount) get no menu.
                return []
            targets.append((file, found[0]))
            any_root = any_root or found[1]
        if not targets:
            return []

        # "View online" first, as in the Windows client, for one item only.
        actions = ("view",) if len(targets) == 1 else ()
        if any_root:
            # Pinning or freeing the whole drive is one click too easy.
            actions += ("download",)
        else:
            states = [self._known_state(file, path) for file, path in targets]
            pin_action = "unpin" if all(s == "pinned" for s in states) else "pin"
            actions += ("download", pin_action, "free")

        top = Nautilus.MenuItem(name=name_prefix + "::menu", label="OneDrive",
                                tip="OneDrive Files On-Demand", icon="")
        submenu = Nautilus.Menu()
        top.set_submenu(submenu)
        for action in actions:
            item = Nautilus.MenuItem(name="%s::%s" % (name_prefix, action),
                                     label=ACTION_TITLES[action], tip="", icon="")
            item.connect("activate", self._on_activate, action, targets)
            submenu.append_item(item)
        return [top]

    def _on_activate(self, _item, action, targets):
        if action == "view":
            self.view_online(*targets[0])
            return
        try:
            folders = [path for file, path in targets if file.is_directory()]
        except Exception as e:
            log("is_directory failed: %s" % e)
            return
        if action == "free" and folders:
            self._confirm_free(folders, targets)
            return
        for file, path in targets:
            self.run_action(file, path, action)

    def _confirm_free(self, folders, targets):
        if len(folders) == 1:
            what = "the folder \u201c%s\u201d" % os.path.basename(folders[0])
        else:
            what = "%d folders" % len(folders)
        text = ("Free up space in %s?\n\nFiles in it will be removed from this device "
                "and stay available online. Files kept on this device will stop being "
                "kept. Files with changes that are not uploaded yet stay." % what)

        def answered(ok):
            if not ok:
                return
            for file, path in targets:
                self.run_action(file, path, "free")

        try:
            self.confirmer("Free up space", text, "Free up space", answered)
        except Exception as e:
            log("confirmation failed: %s" % e)

    def view_online(self, file, path):
        """Read user.onedrive.weburl (a network call in the client, may take
        seconds) in GIO's thread pool, then open it in the default browser."""
        try:
            Gio.File.new_for_path(path).query_info_async(
                WEBURL_GIO_ATTR, Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_DEFAULT,
                None, self._weburl_done, path)
        except Exception as e:
            self._view_failed(path, str(e))

    def _view_failed(self, path, reason):
        self.notifier("OneDrive: View online",
                      "%s: %s" % (os.path.basename(path.rstrip("/")) or path, reason))

    def _weburl_done(self, gfile, result, path):
        try:
            info = gfile.query_info_finish(result)
            url = info.get_attribute_as_string(WEBURL_GIO_ATTR)
        except GLib.Error as e:
            self._view_failed(path, describe_error("view", e))
            return
        except Exception as e:
            log("weburl query failed: %s" % e)
            return
        # GIO drops the attribute on any getxattr failure, so ENODATA (not
        # uploaded yet) and EIO (offline) both end up here.
        url = unescape_gio_string(url).strip() if url else ""
        if not url.startswith(("https://", "http://")):
            self._view_failed(path, "No web link available. The item may not be "
                                    "uploaded yet, or OneDrive is offline.")
            return
        try:
            self.launcher(url, self._launch_done, path)
        except Exception as e:
            self._view_failed(path, str(e))

    def _launch_done(self, error, path):
        if error is not None:
            self._view_failed(path, "Could not open the browser: %s" % error)

    def run_action(self, file, path, action):
        """setxattr(user.onedrive.action) via GIO's thread pool, so a file
        download that blocks in the FUSE daemon does not freeze Nautilus."""
        try:
            gfile = Gio.File.new_for_path(path)
            info = Gio.FileInfo()
            info.set_attribute_string(ACTION_GIO_ATTR, action)
            gfile.set_attributes_async(info, Gio.FileQueryInfoFlags.NONE,
                                       GLib.PRIORITY_DEFAULT, None,
                                       self._action_done, (file, path, action))
        except Exception as e:
            self.notifier("OneDrive: " + ACTION_TITLES.get(action, action),
                          "%s: %s" % (os.path.basename(path), e))

    def _action_done(self, gfile, result, data):
        file, path, action = data
        try:
            gfile.set_attributes_finish(result)
        except GLib.Error as e:
            self.notifier("OneDrive: " + ACTION_TITLES.get(action, action),
                          "%s: %s" % (os.path.basename(path) or path, describe_error(action, e)))
        except Exception as e:
            log("action %s on %s failed: %s" % (action, path, e))
        try:
            file.invalidate_extension_info()
        except Exception as e:
            log("invalidate failed: %s" % e)
