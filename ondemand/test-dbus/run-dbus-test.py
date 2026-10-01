#!/usr/bin/env python3
"""D-Bus status interface test for the onedrive client (io.github.abraunegg.OneDrive1).

Starts throwaway client instances (temporary confdir and sync_dir under $TMPDIR, no account: the
client waits at the authentication prompt, so the service reports State 'starting'), finds them by
bus name prefix, reads all properties, calls GetTransfers/GetIssues/SyncNow/DismissIssue/Pause,
checks introspection, that two instances get different names, and that the names disappear on exit.

Usage: run-dbus-test.py <path to onedrive binary>
"""
import hashlib, os, subprocess, sys, tempfile, time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

PREFIX = "io.github.abraunegg.OneDrive.i"
PATH = "/io/github/abraunegg/OneDrive"
IFACE = "io.github.abraunegg.OneDrive1"
PASS = FAIL = 0

def ok(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1; print("PASS", name)
    else:
        FAIL += 1; print("FAIL", name, detail)

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

def names():
    reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                          "ListNames", None, GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE, -1, None)
    return [n for n in reply.unpack()[0] if n.startswith(PREFIX)]

def expected_name(confdir):
    return PREFIX + hashlib.sha256(os.path.abspath(confdir).encode()).hexdigest()[:16]

def start_instance(binary, base, label):
    confdir = os.path.join(base, label, "conf")
    syncdir = os.path.join(base, label, "sync")
    os.makedirs(confdir); os.makedirs(syncdir)
    with open(os.path.join(confdir, "config"), "w") as f:
        f.write('sync_dir = "%s"\n' % syncdir)
    # stdin stays open: the client waits at the authentication prompt. BROWSER=/bin/true stops it
    # from opening the authorisation URL in the desktop browser.
    env = dict(os.environ, BROWSER="/bin/true")
    proc = subprocess.Popen([binary, "--confdir", confdir, "--monitor"], stdin=subprocess.PIPE, env=env,
                            stdout=open(os.path.join(base, label + ".log"), "w"), stderr=subprocess.STDOUT)
    return proc, confdir, syncdir

def wait_for(pred, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        time.sleep(0.2)
    return False

def main():
    binary = os.path.abspath(sys.argv[1])
    base = tempfile.mkdtemp(prefix="odbus.", dir=os.environ.get("TMPDIR", "/tmp"))
    before = set(names())
    a, confA, syncA = start_instance(binary, base, "a")
    b, confB, syncB = start_instance(binary, base, "b")
    try:
        nameA, nameB = expected_name(confA), expected_name(confB)
        ok("instance A appears on the bus", wait_for(lambda: nameA in names()))
        ok("instance B appears on the bus", wait_for(lambda: nameB in names()))
        ok("two instances have different names", nameA != nameB)
        ok("only our instances are new", set(names()) - before == {nameA, nameB}, str(set(names()) - before))

        proxy = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None, nameA, PATH, IFACE, None)
        props = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None, nameA, PATH,
                                       "org.freedesktop.DBus.Properties", None)
        allprops = props.call_sync("GetAll", GLib.Variant("(s)", (IFACE,)), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        print("GetAll:", allprops)
        expected = {"Version": str, "ConfigDir": str, "SyncDir": str, "Account": str, "AccountType": str,
                    "OnDemand": bool, "Capabilities": list, "State": str, "StateDetail": str,
                    "LastSyncTime": int, "QuotaUsed": int, "QuotaTotal": int, "PendingUploads": int, "PendingDownloads": int}
        ok("GetAll returns every property with the right type",
           all(k in allprops and isinstance(allprops[k], t) for k, t in expected.items()), str(allprops))
        ok("ConfigDir is the absolute confdir", allprops.get("ConfigDir") == os.path.abspath(confA))
        ok("SyncDir is the configured sync_dir", allprops.get("SyncDir") == os.path.abspath(syncA))
        ok("State is starting before authentication", allprops.get("State") == "starting")
        ok("OnDemand false, Capabilities without ondemand/actions/pause",
           allprops.get("OnDemand") is False and set(allprops.get("Capabilities", [])) == {"issues", "transfers"})
        state = props.call_sync("Get", GLib.Variant("(ss)", (IFACE, "State")), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        ok("Get(State)", state == "starting", state)
        try:
            props.call_sync("Get", GLib.Variant("(ss)", (IFACE, "Nope")), Gio.DBusCallFlags.NONE, 5000, None)
            ok("Get of an unknown property fails", False)
        except GLib.Error as e:
            ok("Get of an unknown property fails", "UnknownProperty" in e.message, e.message)

        transfers = proxy.call_sync("GetTransfers", None, Gio.DBusCallFlags.NONE, 5000, None)
        ok("GetTransfers returns a(ssstt)", transfers.get_type_string() == "(a(ssstt))", transfers.get_type_string())
        issues = proxy.call_sync("GetIssues", None, Gio.DBusCallFlags.NONE, 5000, None)
        ok("GetIssues returns a(sssssx)", issues.get_type_string() == "(a(sssssx))", issues.get_type_string())
        ok("SyncNow succeeds", proxy.call_sync("SyncNow", None, Gio.DBusCallFlags.NONE, 5000, None) is not None)
        try:
            proxy.call_sync("DismissIssue", GLib.Variant("(s)", ("nope",)), Gio.DBusCallFlags.NONE, 5000, None)
            ok("DismissIssue of an unknown id fails", False)
        except GLib.Error as e:
            ok("DismissIssue of an unknown id fails", "InvalidArgs" in e.message, e.message)
        try:
            proxy.call_sync("Pause", GLib.Variant("(u)", (5,)), Gio.DBusCallFlags.NONE, 5000, None)
            ok("Pause is refused (no 'pause' capability)", False)
        except GLib.Error as e:
            ok("Pause is refused (no 'pause' capability)", "NotSupported" in e.message, e.message)

        xml = bus.call_sync(nameA, PATH, "org.freedesktop.DBus.Introspectable", "Introspect", None,
                            GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        info = Gio.DBusNodeInfo.new_for_xml(xml)
        iface = info.lookup_interface(IFACE)
        ok("introspection parses and has the interface", iface is not None)
        if iface is not None:
            ok("introspection lists the methods",
               {m.name for m in iface.methods} == {"GetTransfers", "GetIssues", "DismissIssue", "SyncNow", "Pause", "Resume"})
            ok("introspection lists the signals", {s.name for s in iface.signals} == {"IssuesChanged", "TransfersChanged"})
            ok("introspection lists the properties", {p.name for p in iface.properties} == set(expected))
        root = bus.call_sync(nameA, "/", "org.freedesktop.DBus.Introspectable", "Introspect", None,
                             GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        ok("root introspection leads to the object", '<node name="io"/>' in root)
    finally:
        import signal
        for proc in (a, b):
            proc.send_signal(signal.SIGTERM)   # the client's own handler shuts it down
        killed = False
        for proc in (a, b):
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill(); killed = True
        ok("instances exit on SIGTERM without being killed", not killed)
    ok("names disappear on exit", wait_for(lambda: not ({expected_name(confA), expected_name(confB)} & set(names())), 10),
       str(names()))
    print("logs in", base)
    print("PASS %d FAIL %d" % (PASS, FAIL))
    sys.exit(1 if FAIL else 0)

main()
