#!/usr/bin/env python3
# Tests for onedrive-ondemand.py without a running Nautilus.
#
# A temporary directory on a filesystem with user.* xattr support (ext4,
# tmpfs >= 6.6) stands in for the on-demand mount: a fake mounts file lists
# it as fuse.onedrive. The FUSE side is not involved, so user.onedrive.state
# is set by the test and user.onedrive.action is just stored by the kernel.
#
# Run: python3 contrib/nautilus/test_extension.py
# (STUB_NAUTILUS=1 forces the stubbed Nautilus module.)

import builtins
import importlib.util
import os
import sys
import tempfile
import types
import unittest

import gi
from gi.repository import GLib, GObject, Gio

try:
    if os.environ.get("STUB_NAUTILUS"):
        raise ImportError("stub requested")
    gi.require_version("Nautilus", "4.0")
    from gi.repository import Nautilus  # noqa: F401
    REAL_NAUTILUS = True
except (ValueError, ImportError):
    REAL_NAUTILUS = False

    class _Stub(GObject.GObject):
        def __init__(self, **kwargs):
            GObject.GObject.__init__(self)
            self.props_ = kwargs
            self.submenu = None
            self.items = []
            self.handlers = []

        def set_submenu(self, menu):
            self.submenu = menu

        def append_item(self, item):
            self.items.append(item)

        def connect(self, signal, cb, *args):
            self.handlers.append((signal, cb, args))

        def get_property(self, name):
            return self.props_[name]

    class _Iface:
        pass

    stub = types.ModuleType("gi.repository.Nautilus")
    stub.InfoProvider = type("InfoProvider", (_Iface,), {})
    stub.MenuProvider = type("MenuProvider", (_Iface,), {})
    stub.ColumnProvider = type("ColumnProvider", (_Iface,), {})
    stub.MenuItem = stub.Menu = stub.Column = _Stub
    stub.OperationResult = types.SimpleNamespace(COMPLETE=0, IN_PROGRESS=1, FAILED=2)
    sys.modules["gi.repository.Nautilus"] = stub
    gi.repository.Nautilus = stub
    _real_require = gi.require_version
    gi.require_version = lambda ns, v: None if ns == "Nautilus" else _real_require(ns, v)

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("onedrive_ondemand",
                                              os.path.join(HERE, "onedrive-ondemand.py"))
ext = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ext)


def xattr_supported(d):
    probe = os.path.join(d, ".probe")
    open(probe, "w").close()
    try:
        os.setxattr(probe, "user.test", b"1")
        return True
    except OSError:
        return False
    finally:
        os.unlink(probe)


class FakeFileInfo:
    """Duck-typed Nautilus.FileInfo."""

    def __init__(self, path, scheme="file"):
        self.path = path
        self.scheme = scheme
        self.emblems = []
        self.attrs = {}
        self.invalidated = 0

    def get_uri_scheme(self):
        return self.scheme

    def get_uri(self):
        return Gio.File.new_for_path(self.path).get_uri()

    def get_location(self):
        return Gio.File.new_for_path(self.path)

    def add_emblem(self, name):
        self.emblems.append(name)

    def add_string_attribute(self, key, value):
        self.attrs[key] = value

    def invalidate_extension_info(self):
        self.invalidated += 1

    def is_gone(self):
        return not os.path.lexists(self.path)

    def is_directory(self):
        return os.path.isdir(self.path)


def menu_items(top):
    if REAL_NAUTILUS:
        sub = top.get_property("menu")
        return sub.get_items()
    return top.submenu.items


def item_name(item):
    return item.get_property("name")


def item_label(item):
    return item.get_property("label")


def activate(item):
    if REAL_NAUTILUS:
        item.activate()
    else:
        for signal, cb, args in item.handlers:
            cb(item, *args)


def run_loop_until(cond, timeout=5.0):
    ctx = GLib.MainContext.default()
    deadline = GLib.get_monotonic_time() + timeout * 1e6
    while not cond() and GLib.get_monotonic_time() < deadline:
        ctx.iteration(False)
    return cond()


class ExtensionTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        base = None
        for candidate in (None, HERE):
            d = tempfile.mkdtemp(prefix="od-nautilus-test-", dir=candidate)
            if xattr_supported(d):
                base = d
                break
            os.rmdir(d)
        if base is None:
            raise unittest.SkipTest("no filesystem with user xattrs available")
        cls.base = base
        cls.mount = os.path.join(base, "One Drive")  # space tests \040 unescaping
        cls.outside = os.path.join(base, "outside")
        os.makedirs(os.path.join(cls.mount, "Folder", "nested"))
        os.makedirs(cls.outside)
        cls.mounts_file = os.path.join(base, "mounts")
        with open(cls.mounts_file, "w") as f:
            f.write("/dev/sda1 / ext4 rw 0 0\n")
            f.write("onedrive %s fuse.onedrive rw,nosuid 0 0\n"
                    % cls.mount.replace(" ", "\\040"))
            f.write("tmpfs %s tmpfs rw 0 0\n"
                    % os.path.join(cls.mount, "Folder", "nested").replace(" ", "\\040"))

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls.base, ignore_errors=True)

    def setUp(self):
        self.notes = []
        self.questions = []
        self.answer = True

        def confirmer(title, text, ok_label, callback):
            self.questions.append(text)
            callback(self.answer)
        self.x = ext.OneDriveOnDemandExtension(mounts=ext.MountTable(self.mounts_file),
                                               notifier=lambda t, b: self.notes.append((t, b)),
                                               confirmer=confirmer)
        self.file = os.path.join(self.mount, "doc.txt")
        with open(self.file, "w"):
            pass
        os.setxattr(self.file, ext.STATE_XATTR, b"online-only")
        self.folder = os.path.join(self.mount, "Folder")
        os.setxattr(self.folder, ext.STATE_XATTR, b"pinned")
        # Fail loudly if the extension opens anything inside the mount.
        self._open, self._osopen = builtins.open, os.open
        mount = self.mount

        def guard(real):
            def wrapper(p, *a, **k):
                if isinstance(p, (str, bytes)) and os.fsdecode(p).startswith(mount):
                    raise AssertionError("extension opened %s" % p)
                return real(p, *a, **k)
            return wrapper
        builtins.open, os.open = guard(self._open), guard(self._osopen)
        # Folder state must never be read synchronously on the main thread.
        self._getxattr = os.getxattr

        def getxattr(p, *a, **k):
            if os.path.isdir(p):
                raise AssertionError("synchronous getxattr on folder %s" % p)
            return self._getxattr(p, *a, **k)
        ext.os.getxattr = getxattr

    def tearDown(self):
        builtins.open, os.open = self._open, self._osopen
        ext.os.getxattr = self._getxattr
        if self.x.refresh_source is not None:
            GLib.source_remove(self.x.refresh_source)

    def test_mount_detection(self):
        m = self.x.mounts
        self.assertEqual(m.ondemand_mount_for(self.mount), self.mount)
        self.assertEqual(m.ondemand_mount_for(self.file), self.mount)
        self.assertIsNone(m.ondemand_mount_for(self.outside))
        self.assertIsNone(m.ondemand_mount_for(self.mount + "x/file"))
        # innermost mount wins: a tmpfs nested in the on-demand mount is not ours
        self.assertIsNone(m.ondemand_mount_for(os.path.join(self.folder, "nested", "a")))

    def test_update_file_info(self):
        f = FakeFileInfo(self.file)
        self.x.update_file_info(f)
        self.assertEqual(f.emblems, ["weather-overcast-symbolic"])
        self.assertEqual(f.attrs[ext.STATE_ATTRIBUTE], "Online only")
        # Folder: nothing known at first, async read, invalidate, then shown.
        d = FakeFileInfo(self.folder)
        self.x.update_file_info(d)
        self.assertEqual(d.emblems, [])
        self.assertTrue(run_loop_until(lambda: d.invalidated == 1))
        self.x.update_file_info(d)
        self.assertEqual(d.emblems, ["emblem-default-symbolic"])
        # Re-asked right away: served from the cache, no new query.
        self.assertEqual(self.x.pending, set())
        # Mount root: no state read, not tracked for polling.
        root = FakeFileInfo(self.mount)
        self.x.update_file_info(root)
        run_loop_until(lambda: False, timeout=0.2)
        self.assertEqual((root.emblems, root.attrs, root.invalidated), ([], {}, 0))
        self.assertNotIn(root.get_uri(), self.x.tracked)
        out = FakeFileInfo(self.outside)
        self.x.update_file_info(out)
        self.assertEqual((out.emblems, out.attrs), ([], {}))
        self.x.update_file_info(FakeFileInfo(self.file, scheme="trash"))

    def test_menu_outside_and_mixed(self):
        self.assertEqual(self.x.get_file_items([FakeFileInfo(self.outside)]), [])
        self.assertEqual(self.x.get_file_items([FakeFileInfo(self.file),
                                                FakeFileInfo(self.outside)]), [])

    def test_menu_labels(self):
        items = menu_items(self.x.get_file_items([FakeFileInfo(self.file)])[0])
        self.assertEqual([item_label(i) for i in items],
                         ["Download now", "Always keep on this device", "Free up space"])
        d = FakeFileInfo(self.folder)
        items = menu_items(self.x.get_file_items([d])[0])
        self.assertEqual(item_label(items[1]), "Always keep on this device")  # state unknown yet
        self.x.update_file_info(d)
        self.assertTrue(run_loop_until(lambda: d.invalidated == 1))
        items = menu_items(self.x.get_file_items([d])[0])
        self.assertEqual(item_label(items[1]), "Stop keeping on this device")
        bg = menu_items(self.x.get_background_items(FakeFileInfo(self.folder))[0])
        self.assertEqual(len(bg), 3)

    def test_mount_root_menu_only_download(self):
        bg = menu_items(self.x.get_background_items(FakeFileInfo(self.mount))[0])
        self.assertEqual([item_label(i) for i in bg], ["Download now"])
        sel = menu_items(self.x.get_file_items([FakeFileInfo(self.mount + "/"),
                                                FakeFileInfo(self.file)])[0])
        self.assertEqual([item_label(i) for i in sel], ["Download now"])

    def test_free_folder_asks_first(self):
        d = FakeFileInfo(self.folder)
        os.setxattr(self.folder, "user.onedrive.action", b"none")
        self.answer = False
        activate(menu_items(self.x.get_background_items(d)[0])[2])
        self.assertEqual(len(self.questions), 1)
        self.assertIn("Folder", self.questions[0])
        run_loop_until(lambda: False, timeout=0.2)
        self.assertEqual(self._getxattr(self.folder, "user.onedrive.action"), b"none")
        self.answer = True
        activate(menu_items(self.x.get_file_items([d])[0])[2])
        self.assertTrue(run_loop_until(lambda: d.invalidated == 1))
        self.assertEqual(self._getxattr(self.folder, "user.onedrive.action"), b"free")
        self.assertEqual(len(self.questions), 2)

    def test_free_file_no_question(self):
        f = FakeFileInfo(self.file)
        activate(menu_items(self.x.get_file_items([f])[0])[2])
        self.assertTrue(run_loop_until(lambda: f.invalidated == 1))
        self.assertEqual(self.questions, [])
        self.assertEqual(os.getxattr(self.file, "user.onedrive.action"), b"free")

    def test_zenity_confirm_async(self):
        # true/false stand in for zenity (they ignore the arguments).
        for program, expected in (("true", True), ("false", False),
                                  ("no-such-zenity-binary", False)):
            got = []
            ext.confirm_with_zenity("t", "q", "ok", got.append, program=program)
            self.assertTrue(run_loop_until(lambda: got), program)
            self.assertEqual(got, [expected], program)

    def test_actions_write_xattr(self):
        for target, index, expected in ((self.file, 0, b"download"),
                                        (self.file, 1, b"pin"),
                                        (self.folder, 1, b"unpin"),
                                        (self.folder, 2, b"free")):
            f = FakeFileInfo(target)
            if f.is_directory() and f.get_uri() not in self.x.tracked:  # let the async read land
                self.x.update_file_info(f)
                run_loop_until(lambda: f.invalidated == 1)
                f.invalidated = 0
            items = menu_items(self.x.get_file_items([f])[0])
            activate(items[index])
            self.assertTrue(run_loop_until(lambda: f.invalidated == 1), item_name(items[index]))
            self.assertEqual(self._getxattr(target, "user.onedrive.action"), expected)
        self.assertEqual(self.notes, [])

    def test_action_error_notifies(self):
        gone = os.path.join(self.mount, "gone.txt")
        f = FakeFileInfo(gone)
        self.x.run_action(f, gone, "free")
        self.assertTrue(run_loop_until(lambda: f.invalidated == 1))
        self.assertEqual(len(self.notes), 1)
        self.assertIn("gone.txt", self.notes[0][1])

    def test_error_messages(self):
        busy = GLib.Error.new_literal(Gio.io_error_quark(), "busy", Gio.IOErrorEnum.BUSY)
        self.assertIn("kept on this device", ext.describe_error("free", busy))
        again = GLib.Error.new_literal(Gio.io_error_quark(), "again", Gio.IOErrorEnum.WOULD_BLOCK)
        self.assertIn("Try again", ext.describe_error("download", again))
        # errno mapping GIO applies to setxattr failures
        self.assertEqual(Gio.io_error_from_errno(16), Gio.IOErrorEnum.BUSY)       # EBUSY
        self.assertEqual(Gio.io_error_from_errno(11), Gio.IOErrorEnum.WOULD_BLOCK)  # EAGAIN

    def test_refresh_invalidates_changed(self):
        f = FakeFileInfo(self.file)
        self.x.update_file_info(f)
        self.assertIsNotNone(self.x.refresh_source)
        os.setxattr(self.file, ext.STATE_XATTR, b"hydrated")
        self.x._refresh()
        self.assertTrue(run_loop_until(lambda: f.invalidated == 1))
        f.emblems = []
        self.x.update_file_info(f)
        self.assertEqual(f.emblems, ["emblem-ok-symbolic"])
        # unchanged state: no invalidation
        self.x._refresh()
        run_loop_until(lambda: False, timeout=0.3)
        self.assertEqual(f.invalidated, 1)

    def test_columns(self):
        cols = self.x.get_columns()
        self.assertEqual(len(cols), 1)


if __name__ == "__main__":
    print("real Nautilus 4.0 bindings: %s" % REAL_NAUTILUS)
    unittest.main(verbosity=2)
