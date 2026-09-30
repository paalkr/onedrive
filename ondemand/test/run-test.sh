#!/bin/bash
# Mounts odtest on a temp mountpoint outside any git repo, exercises it and
# always unmounts. Usage: run-test.sh <odtest binary>
set -u
BIN="$(realpath "${1:?usage: run-test.sh <odtest binary>}")"
T="$(mktemp -d "${TMPDIR:-/tmp}/odtest.XXXXXX")"
W="$T/work"; M="$T/mnt"; LOG="$T/odtest.log"
mkdir -p "$W" "$M"
case "$(cd "$M" && git rev-parse --is-inside-work-tree 2>/dev/null)" in
	true) echo "mountpoint $M is inside a git work tree, refusing"; exit 2;;
esac

PID=
cleanup() {
	touch "$W/stop"
	for i in $(seq 1 50); do [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
	[ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
	grep -q " $M fuse" /proc/mounts && fusermount3 -u -z "$M"
}
trap cleanup EXIT

# 300 ms artificial download delay so concurrent readers overlap
timeout 120 "$BIN" "$W" "$M" 300 > "$LOG" 2>&1 &
PID=$!
for i in $(seq 1 50); do grep -q READY "$LOG" && break; sleep 0.1; done
grep -q READY "$LOG" || { echo "not ready"; cat "$LOG"; exit 1; }

PASS=0; FAIL=0
ok() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
t() { timeout 10 "$@"; }
downloads() { grep -c "^STUB download $1 to " "$LOG"; }
# rename via renameat2 with flags; prints OK or the errno name
ren() { t python3 -c '
import ctypes, errno, os, sys
libc = ctypes.CDLL(None, use_errno=True)
r = libc.renameat2(-100, sys.argv[1].encode(), -100, sys.argv[2].encode(), int(sys.argv[3]))
print("OK" if r == 0 else errno.errorcode[ctypes.get_errno()])' "$1" "$2" "${3:-0}"; }
catErr() { t python3 -c '
import errno, sys
try:
    open(sys.argv[1]).read(); print("OK")
except OSError as e:
    print(errno.errorcode[e.errno])' "$1"; }
event() { sleep 0.3; grep -qxF "EVENT $1" "$LOG"; }
xget() { t python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], sys.argv[2]).decode())' "$1" "$2" 2>&1; }
xset() { t python3 -c 'import os,sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())' "$1" "$2" "$3" 2>&1; }
B="$W/backing"; R="$W/remote"

echo "== ls -la $M $M/docs"
t ls -la "$M" "$M/docs" | sed "s|$T|\$T|"
BIGSIZE=$(stat -c %s "$R/docs/big.txt")
ok "stat size of online-only file = remote size ($BIGSIZE)" '[ "$(t stat -c %s "$M/docs/big.txt")" = "$BIGSIZE" ]'
ok "stat mtime of online-only file from DB (1704164645)" '[ "$(t stat -c %Y "$M/docs/big.txt")" = 1704164645 ]'
ok "stat mode of online-only file is 0600 regular" '[ "$(t stat -c %A "$M/docs/big.txt")" = "-rw-------" ]'
ok "readdir lists DB children and backing entries" '[ "$(t ls "$M" | tr "\n" " ")" = "apply deferred.txt docs dst3.txt emptydir etag held.txt hold lib local.txt notify offline.txt one.txt pinned.xlsx report.xlsx shared src3.txt syncdir thumb.jpg write-me.txt " ]'
ok "online-only file not in backing dir" '[ ! -e "$B/docs/big.txt" ]'
ok "state xattr online-only" '[ "$(xget "$M/docs/big.txt" user.onedrive.state)" = online-only ]'
ok "open+close without read does not hydrate" 't python3 -c "import os; os.close(os.open(\"$M/docs/pin-me.txt\", os.O_RDONLY))" && [ "$(downloads docs/pin-me.txt)" = 0 ]'
ok "no download after ls/stat/xattr/open" '! grep -q "^STUB download" "$LOG"'

echo "== 10 concurrent cat of docs/big.txt"
EXP=$(md5sum < "$R/docs/big.txt")
CATS=
for i in $(seq 1 10); do (t cat "$M/docs/big.txt" | md5sum >> "$T/md5s") & CATS="$CATS $!"; done
wait $CATS
sort "$T/md5s" | uniq -c
ok "all 10 readers got the remote content" '[ "$(grep -cxF "$EXP" "$T/md5s")" = 10 ]'
ok "hydrated exactly once" '[ "$(downloads docs/big.txt)" = 1 ]'
ok "backing file present after read" '[ -f "$B/docs/big.txt" ]'
ok "state xattr hydrated after read" '[ "$(xget "$M/docs/big.txt" user.onedrive.state)" = hydrated ]'
ok "backing mtime set from DB" '[ "$(stat -c %Y "$B/docs/big.txt")" = 1704164645 ]'

echo "== O_TRUNC write of online-only docs/trunc.txt"
t sh -c "echo new > '$M/docs/trunc.txt'"
ok "O_TRUNC did not hydrate" '[ "$(downloads docs/trunc.txt)" = 0 ]'
ok "V12 O_TRUNC used createEmpty" 'grep -q "^STUB createEmpty .*docs/trunc.txt$" "$LOG"'
ok "O_TRUNC content" '[ "$(t cat "$M/docs/trunc.txt")" = new ] && [ "$(cat "$B/docs/trunc.txt")" = new ]'
ok "O_TRUNC event changed" 'event "changed ./docs/trunc.txt"'

echo "== in-place write of online-only write-me.txt"
t sh -c "printf XY | dd of='$M/write-me.txt' bs=1 seek=2 conv=notrunc status=none"
ok "write hydrated once" '[ "$(downloads write-me.txt)" = 1 ]'
ok "write content" '[ "$(cat "$B/write-me.txt")" = 01XY456789 ]'
ok "write event changed" 'event "changed ./write-me.txt"'

echo "== create, mkdir"
t sh -c "echo hello > '$M/new.txt'"
ok "create backing file" '[ "$(cat "$B/new.txt")" = hello ]'
ok "create event changed" 'event "changed ./new.txt"'
t mkdir "$M/newdir"
ok "mkdir backing dir" '[ -d "$B/newdir" ]'
ok "mkdir event createDir" 'event "createDir ./newdir"'
ok "I2 state xattr local for item not in DB" '[ "$(xget "$M/new.txt" user.onedrive.state)" = local ]'

echo "== rename online-only file"
t mv "$M/docs/move-me.txt" "$M/docs/moved.txt"
ok "rename: new path in backing, old gone" '[ -f "$B/docs/moved.txt" ] && [ ! -e "$B/docs/move-me.txt" ]'
ok "rename: listing shows only new name" 't ls "$M/docs" | grep -qx moved.txt && ! t ls "$M/docs" | grep -qx move-me.txt'
ok "rename event moved" 'event "moved ./docs/move-me.txt -> ./docs/moved.txt"'
echo "   (downloads of move-me.txt for the rename: $(downloads docs/move-me.txt))"

echo "== rename directory with online-only child"
t mv "$M/docs/sub" "$M/docs/sub2"
ok "rename dir event moved" 'event "moved ./docs/sub -> ./docs/sub2"'
ok "online-only child visible under new dir name" '[ "$(t stat -c %s "$M/docs/sub2/deep.txt")" = 5 ]'
ok "old dir name gone" '! t stat "$M/docs/sub" >/dev/null 2>&1'
ok "dir rename did not hydrate the child" '[ "$(downloads docs/sub/deep.txt)" = 0 ]'

echo "== unlink, rmdir"
t rm "$M/docs/delete-me.txt"
ok "unlink online-only: no download" '[ "$(downloads docs/delete-me.txt)" = 0 ]'
ok "unlink event deleted" 'event "deleted ./docs/delete-me.txt"'
ok "unlinked file gone from listing and stat" '! t ls "$M/docs" | grep -qx delete-me.txt && ! t stat "$M/docs/delete-me.txt" >/dev/null 2>&1'
ok "rmdir of dir with online-only child is ENOTEMPTY" 't rmdir "$M/docs/sub2" 2>&1 | grep -q "not empty"'
t rmdir "$M/emptydir"
ok "rmdir backing dir removed" '[ ! -e "$B/emptydir" ]'
ok "rmdir event deleted" 'event "deleted ./emptydir"'

echo "== V12 truncate -s 0 of online-only file"
t truncate -s 0 "$M/docs/trunc0.txt"
ok "V12 truncate 0 used createEmpty, no download" 'grep -q "^STUB createEmpty .*docs/trunc0.txt$" "$LOG" && [ "$(downloads docs/trunc0.txt)" = 0 ]'
ok "V12 truncate 0 size and event" '[ "$(t stat -c %s "$M/docs/trunc0.txt")" = 0 ] && event "changed ./docs/trunc0.txt"'

echo "== V3 rename onto directories and files judged by the mount view"
t mkdir "$M/srcdir"
ok "V3 dir onto dir with only online-only children: ENOTEMPTY" '[ "$(ren "$M/srcdir" "$M/docs/target")" = ENOTEMPTY ]'
ok "V3 target dir and its child intact" '[ -d "$B/docs/target" ] && [ -d "$B/srcdir" ] && [ "$(t stat -c %s "$M/docs/target/t.txt")" = 11 ]'
ok "V3 dir onto online-only file: ENOTDIR" '[ "$(ren "$M/srcdir" "$M/docs/victim.txt")" = ENOTDIR ]'
ok "V3 file onto dir: EISDIR" '[ "$(ren "$M/new.txt" "$M/docs/target")" = EISDIR ]'
ok "V3 RENAME_NOREPLACE onto existing online-only file: EEXIST" '[ "$(ren "$M/new.txt" "$M/docs/victim.txt" 1)" = EEXIST ]'
ok "V3 RENAME_EXCHANGE: EINVAL" '[ "$(ren "$M/new.txt" "$M/docs/victim.txt" 2)" = EINVAL ]'
ok "V3 no move events for refused renames" '! grep -q "^EVENT moved ./srcdir\|^EVENT moved ./new.txt" "$LOG"'
t sh -c "echo replacement > '$M/repl.txt'"
ok "V3 file replacing an online-only file is allowed" '[ "$(ren "$M/repl.txt" "$M/docs/victim2.txt")" = OK ] && event "moved ./repl.txt -> ./docs/victim2.txt"'
ok "V3 replaced file shows the new content, old not downloaded" '[ "$(t cat "$M/docs/victim2.txt")" = replacement ] && [ "$(downloads docs/victim2.txt)" = 0 ]'
ok "V3 replaced file listed once" '[ "$(t ls "$M/docs" | grep -cx victim2.txt)" = 1 ]'

echo "== V4 no download through a pending move"
t mv "$M/hold/d1" "$M/hold/d2"
S0=$(date +%s)
# The FUSE layer fails with EAGAIN; a buffered read goes through the page cache, which reports EIO
ok "V4 read through unapplied move fails (EAGAIN, seen as EIO)" 'case "$(catErr "$M/hold/d2/g.txt")" in EAGAIN|EIO) true;; *) false;; esac'
echo "   (read waited $(( $(date +%s) - S0 ))s)"
ok "V4 O_TRUNC through unapplied move fails with EAGAIN" '! t sh -c "echo x > $M/hold/d2/g.txt" 2>/dev/null'
ok "V4 old dir not resurrected, nothing downloaded" '[ ! -e "$B/hold/d1" ] && [ "$(downloads hold/d1/g.txt)" = 0 ] && ! grep -q "createEmpty .*g.txt" "$LOG"'
ok "V4 pin through unapplied move refused, nothing downloaded" '! xset "$M/hold/d2/g.txt" user.onedrive.pin 1 >/dev/null 2>&1; [ "$(xget "$M/hold/d2/g.txt" user.onedrive.state)" = online-only ] && [ ! -e "$B/hold/d1" ]'
ok "V4 file still listed under the new dir" 't ls "$M/hold/d2" | grep -qx g.txt'
t mv "$M/apply/d1" "$M/apply/d2"
ok "V4 read waits for the applied move, then hydrates" '[ "$(t cat "$M/apply/d2/f.txt")" = "applied move" ] && grep -q "^APPLIED ./apply/d1 -> ./apply/d2" "$LOG"'
ok "V4 download landed at the new path only" 'grep -q "^STUB download apply/d1/f.txt to .*apply/d2/f.txt$" "$LOG" && [ -f "$B/apply/d2/f.txt" ] && [ ! -e "$B/apply/d1" ]'

echo "== V-partial"
echo "engine staging" > "$B/docs/big.txt.partial"
ok "V-partial engine .partial hidden from readdir" '! t ls "$M/docs" | grep -qx big.txt.partial'
ok "V-partial engine .partial ENOENT for stat and open" '! t stat "$M/docs/big.txt.partial" >/dev/null 2>&1 && [ "$(catErr "$M/docs/big.txt.partial")" = ENOENT ]'
ok "V-partial DB item named .partial stays visible" 't ls "$M/docs" | grep -qx keep.partial && [ "$(t stat -c %s "$M/docs/keep.partial")" = 22 ]'
ok "V-partial creating a .partial name is refused" '! t sh -c "echo x > $M/user.partial" 2>/dev/null && [ ! -e "$B/user.partial" ]'

echo "== V2 rename across drives"
ok "V2 shared folder from another drive is listed" 't ls "$M" | grep -qx shared'
ok "V2 rename into a shared folder: EXDEV" '[ "$(ren "$M/new.txt" "$M/shared/new.txt")" = EXDEV ] && [ -f "$B/new.txt" ]'
t sh -c "echo s > '$M/shared/s.txt'"
ok "V2 rename out of a shared folder: EXDEV" '[ "$(ren "$M/shared/s.txt" "$M/s.txt")" = EXDEV ]'
ok "V2 rename inside a shared folder works" '[ "$(ren "$M/shared/s.txt" "$M/shared/s2.txt")" = OK ]'

echo "== utimens on hydrated file"
t touch -d "2020-01-01 00:00:00 UTC" "$M/local.txt"
ok "utimens backing mtime" '[ "$(stat -c %Y "$B/local.txt")" = 1577836800 ]'
ok "utimens event changed" 'event "changed ./local.txt"'

echo "== xattr pin"
ok "state xattr hydrated for local file" '[ "$(xget "$M/local.txt" user.onedrive.state)" = hydrated ]'
ok "state xattr is read-only" 'xset "$M/local.txt" user.onedrive.state x | grep -q "Operation not permitted"'
xset "$M/docs/pin-me.txt" user.onedrive.pin 1
ok "pin=1 hydrates once" '[ "$(downloads docs/pin-me.txt)" = 1 ] && [ -f "$B/docs/pin-me.txt" ]'
ok "pin=1 state pinned, pin xattr 1" '[ "$(xget "$M/docs/pin-me.txt" user.onedrive.state)" = pinned ] && [ "$(xget "$M/docs/pin-me.txt" user.onedrive.pin)" = 1 ]'
xset "$M/docs/pin-me.txt" user.onedrive.pin 0
ok "pin=0 state hydrated" '[ "$(xget "$M/docs/pin-me.txt" user.onedrive.state)" = hydrated ]'

echo "== I2 st_blocks"
ok "I2 st_blocks 0 for online-only file" '[ "$(t stat -c %b "$M/lib/a.txt")" = 0 ] && [ "$(t du -k "$M/lib/a.txt" | cut -f1)" = 0 ]'
ok "I2 st_blocks of hydrated file from backing file" '[ "$(t stat -c %b "$M/docs/big.txt")" = "$(stat -c %b "$B/docs/big.txt")" ] && [ "$(t stat -c %b "$M/docs/big.txt")" -gt 0 ]'

echo "== I2 user.onedrive.action on a file"
act() { xset "$1" user.onedrive.action "$2"; }
ok "I2 listxattr lists only the state" '[ "$(t python3 -c "import os,sys; print(\" \".join(os.listxattr(sys.argv[1])))" "$M/one.txt")" = user.onedrive.state ]'
ok "I2 action is write-only (ENODATA on read)" 'xget "$M/one.txt" user.onedrive.action | grep -q "No data available"'
ok "I2 unknown action: EINVAL" 'act "$M/one.txt" bogus | grep -q "Invalid argument"'
act "$M/one.txt" download
ok "I2 file download: hydrated, backing present" '[ "$(xget "$M/one.txt" user.onedrive.state)" = hydrated ] && [ -f "$B/one.txt" ] && [ "$(downloads one.txt)" = 1 ]'
act "$M/one.txt" free
ok "I2 file free: online-only, backing gone, size kept" '[ "$(xget "$M/one.txt" user.onedrive.state)" = online-only ] && [ ! -e "$B/one.txt" ] && [ "$(t stat -c %s "$M/one.txt")" = 19 ]'
act "$M/one.txt" pin
ok "I2 file pin: pinned" '[ "$(xget "$M/one.txt" user.onedrive.state)" = pinned ] && [ -f "$B/one.txt" ]'
ok "I2 free of a pinned file: EBUSY, file kept" 'act "$M/one.txt" free | grep -q "Device or resource busy" && [ -f "$B/one.txt" ]'
act "$M/one.txt" unpin
ok "I2 file unpin: hydrated, not dehydrated" '[ "$(xget "$M/one.txt" user.onedrive.state)" = hydrated ] && [ -f "$B/one.txt" ]'
ok "I2 free of an online-only file with an unuploaded local change: EBUSY" 'act "$M/docs/trunc.txt" free | grep -q "Device or resource busy" && [ "$(cat "$B/docs/trunc.txt")" = new ]'
ok "I2 action on item not in DB: EOPNOTSUPP" 'act "$M/new.txt" pin | grep -q "Operation not supported"'

echo "== I2 user.onedrive.action on a directory"
ok "I2 directory state online-only while a file below is" '[ "$(xget "$M/lib" user.onedrive.state)" = online-only ]'
act "$M/lib" download
ok "I2 dir download hydrates every file below" '[ -f "$B/lib/a.txt" ] && [ -f "$B/lib/b.txt" ] && [ -f "$B/lib/sub/c.txt" ] && [ "$(xget "$M/lib/sub/c.txt" user.onedrive.state)" = hydrated ]'
ok "I2 directory state hydrated when all below are" '[ "$(xget "$M/lib" user.onedrive.state)" = hydrated ] && [ "$(xget "$M/lib/sub" user.onedrive.state)" = hydrated ]'
act "$M/lib" pin
ok "I2 dir pin: dir and files pinned" '[ "$(xget "$M/lib" user.onedrive.state)" = pinned ] && [ "$(xget "$M/lib/sub/c.txt" user.onedrive.state)" = pinned ]'
ok "I2 free of a file in a pinned directory: EBUSY" 'act "$M/lib/a.txt" free | grep -q "Device or resource busy" && [ -f "$B/lib/a.txt" ]'
act "$M/lib" unpin
ok "I2 dir unpin: hydrated, files kept" '[ "$(xget "$M/lib" user.onedrive.state)" = hydrated ] && [ "$(xget "$M/lib/a.txt" user.onedrive.state)" = hydrated ] && [ -f "$B/lib/a.txt" ]'
act "$M/lib" pin
act "$M/lib" free
ok "I2 dir free (from pinned): unpins, dehydrates every file" '[ ! -e "$B/lib/a.txt" ] && [ ! -e "$B/lib/b.txt" ] && [ ! -e "$B/lib/sub/c.txt" ] && [ "$(xget "$M/lib/sub/c.txt" user.onedrive.state)" = online-only ]'
ok "I2 dir state online-only after free, sizes kept" '[ "$(xget "$M/lib" user.onedrive.state)" = online-only ] && [ "$(t stat -c %s "$M/lib/b.txt")" = 9 ]'
sleep 1.2   # let the kernel's 1 s attribute cache of the freed files expire
echo "   (du -sk lib after free: $(t du -sk "$M/lib" | cut -f1) kB, backing dirs: $(du -sk "$B/lib" | cut -f1) kB)"
ok "I2 du after free counts only the directories" '[ "$(t du -sk "$M/lib" | cut -f1)" = "$(du -sk "$B/lib" | cut -f1)" ]'
ok "I2 pin alias on a directory" 'xset "$M/lib" user.onedrive.pin 1 && [ "$(xget "$M/lib" user.onedrive.state)" = pinned ] && [ "$(xget "$M/lib" user.onedrive.pin)" = 1 ]'

echo "== R1 free of an open file"
t cat "$M/held.txt" >/dev/null
exec 7>>"$M/held.txt"
ok "R1 free while open for writing: EBUSY, file intact" 'act "$M/held.txt" free | grep -q "Device or resource busy" && [ "$(cat "$B/held.txt")" = "held open" ]'
exec 7>&-
sleep 0.3   # FUSE sends RELEASE after close() returns
act "$M/held.txt" free
ok "R1 free after close works" '[ "$(xget "$M/held.txt" user.onedrive.state)" = online-only ] && [ ! -e "$B/held.txt" ]'
exec 8<"$M/held.txt"
t mv "$M/held.txt" "$M/held-moved.txt"
exec 8<&-
sleep 0.3
ok "R1 noteOpen/noteClose balanced, also for a handle moved while open" '[ "$(grep -c "^STUB noteOpen " "$LOG")" = "$(grep -c "^STUB noteClose [^U]" "$LOG")" ] && ! grep -q UNBALANCED "$LOG" && [ "$(grep -c "^STUB noteOpen " "$LOG")" -gt 0 ]'
echo "   (noteOpen $(grep -c "^STUB noteOpen " "$LOG"), noteClose $(grep -c "^STUB noteClose [^U]" "$LOG"))"

echo "== R5 thumbnailers never hydrate"
mkdir -p "$T/bin"
cp /usr/bin/cat "$T/bin/gdk-pixbuf-thumbnailer"
cp "$(readlink -f "$(command -v python3)")" "$T/bin/evince-thumbnailer"
ok "R5 thumbnailer by comm (gdk-pixbuf-thum): EIO" '! t "$T/bin/gdk-pixbuf-thumbnailer" "$M/thumb.jpg" >/dev/null 2>&1 && ! t "$T/bin/gdk-pixbuf-thumbnailer" "$M/thumb.jpg" >/dev/null 2>&1'
ok "R5 thumbnailer by exe with comm changed to reader: EIO" '! t "$T/bin/evince-thumbnailer" -c "import ctypes,sys; ctypes.CDLL(None).prctl(15, b\"reader\", 0, 0, 0); open(sys.argv[1]).read()" "$M/thumb.jpg" 2>/dev/null'
ok "R5 nothing downloaded for thumbnailers" '[ "$(downloads thumb.jpg)" = 0 ] && [ ! -e "$B/thumb.jpg" ]'
# The client log is written by a logger thread; wait for it
for i in $(seq 1 30); do grep -q "not downloading ./thumb.jpg" "$LOG" && break; sleep 0.1; done
sleep 0.5
ok "R5 one log line per item" '[ "$(grep -c "not downloading ./thumb.jpg for thumbnailer" "$LOG")" = 1 ]'
grep "not downloading ./thumb.jpg" "$LOG" | sed "s/^/   /"
ok "R5 an ordinary reader still hydrates" '[ "$(t cat "$M/thumb.jpg")" = "not really a jpeg" ] && [ "$(downloads thumb.jpg)" = 1 ]'
ok "R5 thumbnailer may read a hydrated file" '[ "$(t "$T/bin/gdk-pixbuf-thumbnailer" "$M/thumb.jpg")" = "not really a jpeg" ]'

echo "== RO rename-over from a file not in the database (editor save)"
t sh -c "echo saved report > '$M/lu3535390rjnugi.tmp'"
ok "RO rename tmp over hydrated file" '[ "$(ren "$M/lu3535390rjnugi.tmp" "$M/report.xlsx")" = OK ] && event "moved ./lu3535390rjnugi.tmp -> ./report.xlsx"'
ok "RO state hydrated at once, not local" '[ "$(xget "$M/report.xlsx" user.onedrive.state)" = hydrated ] && [ "$(t cat "$M/report.xlsx")" = "saved report" ]'
t sh -c "echo saved pinned > '$M/lu9999.tmp'"
ok "RO rename tmp over pinned file" '[ "$(ren "$M/lu9999.tmp" "$M/pinned.xlsx")" = OK ]'
ok "RO state pinned at once" '[ "$(xget "$M/pinned.xlsx" user.onedrive.state)" = pinned ]'
for i in $(seq 1 30); do grep -q "^CHANGED ./pinned.xlsx" "$LOG" && break; sleep 0.1; done
ok "RO after the engine processed it: still hydrated / pinned" 'grep -q "^CHANGED ./report.xlsx" "$LOG" && grep -q "^CHANGED ./pinned.xlsx" "$LOG" && [ "$(xget "$M/report.xlsx" user.onedrive.state)" = hydrated ] && [ "$(xget "$M/pinned.xlsx" user.onedrive.state)" = pinned ]'
ok "RO listed once, content kept" '[ "$(t ls "$M" | grep -cx pinned.xlsx)" = 1 ] && [ "$(t cat "$M/pinned.xlsx")" = "saved pinned" ]'

echo "== RO rename of a DB file over a DB file, destination changed by the engine"
ok "RO rename src2 over pinned dst2" '[ "$(ren "$M/etag/src2.txt" "$M/etag/dst2.txt")" = OK ]'
ok "RO while pending: shows the moved item (hydrated)" '[ "$(xget "$M/etag/dst2.txt" user.onedrive.state)" = hydrated ]'
for i in $(seq 1 30); do grep -q "^CHANGED ./etag/dst2.txt" "$LOG" && break; sleep 0.1; done
ok "RO destination eTag changed: pending replace cleared, dst2 item (pinned) shown" '[ "$(xget "$M/etag/dst2.txt" user.onedrive.state)" = pinned ]'

echo "== RO rename over a DB file that the engine never processes"
ok "RO rename src3 over pinned dst3" '[ "$(ren "$M/src3.txt" "$M/dst3.txt")" = OK ]'
ok "RO while pending: shows the moved item (hydrated)" '[ "$(xget "$M/dst3.txt" user.onedrive.state)" = hydrated ]'
sleep 16   # onDemandPendingExpirySeconds is 15 in odtest
ok "RO replace expires: dst3 item (pinned) shown, source path stays hidden" '[ "$(xget "$M/dst3.txt" user.onedrive.state)" = pinned ] && ! t ls "$M" | grep -qx src3.txt'
for i in $(seq 1 30); do grep -q "rename over ./dst3.txt not processed" "$LOG" && break; sleep 0.1; done
ok "RO expiry logged" 'grep -q "rename over ./dst3.txt not processed by the engine in time" "$LOG"'

ctl() {
	local n; n=$(grep -cx "CTL $1" "$LOG")
	touch "$W/ctl/$1"
	for i in $(seq 1 30); do [ "$(grep -cx "CTL $1" "$LOG")" -gt "$n" ] && return; sleep 0.1; done
	echo "   ctl $1 not seen"
}
mkdir -p "$W/ctl"

echo "== I3 transient states"
ctl "transient~f-s1~syncing"
ok "I3 file syncing" '[ "$(xget "$M/syncdir/s1.txt" user.onedrive.state)" = syncing ]'
ok "I3 directory syncing when a file below is" '[ "$(xget "$M/syncdir" user.onedrive.state)" = syncing ]'
ctl "transient~f-s1~none"; ctl "transient~f-s2~pending"
ok "I3 file pending, directory pending" '[ "$(xget "$M/syncdir/s2.txt" user.onedrive.state)" = pending ] && [ "$(xget "$M/syncdir" user.onedrive.state)" = pending ] && [ "$(xget "$M/syncdir/s1.txt" user.onedrive.state)" = hydrated ]'
ctl "transient~f-s1~error"
ok "I3 pending beats error in a directory" '[ "$(xget "$M/syncdir" user.onedrive.state)" = pending ] && [ "$(xget "$M/syncdir/s1.txt" user.onedrive.state)" = error ]'
ctl "transient~f-s2~none"
ok "I3 directory error" '[ "$(xget "$M/syncdir" user.onedrive.state)" = error ]'
ctl "transient~f-s1~none"
ok "I3 cleared: stored state again" '[ "$(xget "$M/syncdir" user.onedrive.state)" = hydrated ] && [ "$(xget "$M/syncdir/s1.txt" user.onedrive.state)" = hydrated ]'

echo "== I3 user.onedrive.weburl"
ok "I3 weburl of a file" '[ "$(xget "$M/one.txt" user.onedrive.weburl)" = "https://onedrive.example/drive1/f-one" ]'
ok "I3 weburl of a directory" '[ "$(xget "$M/syncdir" user.onedrive.weburl)" = "https://onedrive.example/drive1/d-sync" ]'
ok "I3 weburl of an item not in DB: ENODATA" 'xget "$M/new.txt" user.onedrive.weburl | grep -q "No data available"'
ok "I3 weburl offline: EIO" 'xget "$M/offline.txt" user.onedrive.weburl | grep -q "Input/output error"'
ok "I3 weburl is read-only" 'xset "$M/one.txt" user.onedrive.weburl x | grep -q "Operation not permitted"'
ok "I3 weburl not listed" '! t python3 -c "import os,sys; print(os.listxattr(sys.argv[1]))" "$M/one.txt" | grep -q weburl'
ok "I3 weburl did not hydrate" '[ ! -e "$B/offline.txt" ]'
URLS=
for i in $(seq 1 16); do (xget "$M/syncdir" user.onedrive.weburl >/dev/null) & URLS="$URLS $!"; done
sleep 0.3
S0=$(date +%s%N); t stat "$M/local.txt" >/dev/null; S1=$(date +%s%N)
wait $URLS
echo "   (stat during 16 slow weburl lookups: $(( (S1 - S0) / 1000000 )) ms)"
ok "I3 16 slow weburl lookups do not block other requests" '[ $(( (S1 - S0) / 1000000 )) -lt 500 ]'

echo "== I3 deferred online change re-evaluated on the last close"
exec 5<"$M/deferred.txt"
exec 6<"$M/deferred.txt"
ctl "defer~f-deferred"
exec 5<&-
sleep 0.5
ok "I3 not re-evaluated while another handle is open" '! grep -q "reevaluate deferred f-deferred" "$LOG"'
exec 6<&-
for i in $(seq 1 20); do grep -q "reevaluate deferred f-deferred" "$LOG" && break; sleep 0.05; done
ok "I3 re-evaluated promptly on the last close, once" '[ "$(grep -c "reevaluate deferred f-deferred" "$LOG")" = 1 ]'

echo "== N notifyBackingChange: engine changes reach inotify watchers of the mount"
NB="$B/notify"; EV="$T/inotify"
timeout 120 python3 "$(dirname "$0")/inotify-watch.py" "$M/notify" > "$EV" 2>&1 &
WATCH=$!
timeout 120 gio monitor -d "$M/notify" > "$T/gio" 2>&1 &
GIOMON=$!
for i in $(seq 1 30); do grep -q WATCHING "$EV" && break; sleep 0.1; done
sleep 0.5
mark() { MARK=$(wc -l < "$EV"); }
since() { sleep 0.5; tail -n +$((MARK + 1)) "$EV" | tr '\n' ' '; }
EVENTS0=$(grep -c "^EVENT " "$LOG")
t ls "$M/notify" >/dev/null
mark; echo "downloaded" > "$NB/n1.txt"; sleep 0.3
ok "N a change behind the mount alone reaches no watcher" '[ -z "$(since)" ]'
mark; ctl "backing~changed~.%notify%n1.txt"; E=$(since); echo "   create: $E"
ok "N create: IN_CREATE" 'echo "$E" | grep -q "IN_CREATE n1.txt"'
ok "N create: listed, content" 't ls "$M/notify" | grep -qx n1.txt && [ "$(t cat "$M/notify/n1.txt")" = downloaded ]'
echo "replaced with longer content" > "$NB/n1.txt"; touch -d "2021-05-05 05:05:05 UTC" "$NB/n1.txt"
mark; ctl "backing~changed~.%notify%n1.txt"; E=$(since); echo "   replace: $E"
# utimensat with an mtime is reported as IN_MODIFY (GIO: "changed")
ok "N replace: IN_MODIFY" 'echo "$E" | grep -q "IN_MODIFY n1.txt"'
echo "   (mount: $(t stat -c %s:%Y "$M/notify/n1.txt"), backing: $(stat -c %s:%Y "$NB/n1.txt"))"
ok "N replace: new size and mtime at once" '[ "$(t stat -c %s:%Y "$M/notify/n1.txt")" = 29:1620191105 ]'
echo "move me" > "$NB/n2.txt"; ctl "backing~changed~.%notify%n2.txt"; sleep 0.3
mv "$NB/n2.txt" "$NB/n3.txt"
mark; ctl "backing~moved~.%notify%n3.txt~.%notify%n2.txt"; E=$(since); echo "   rename: $E"
ok "N rename: IN_MOVED_FROM n2 and IN_MOVED_TO n3" 'echo "$E" | grep -q "IN_MOVED_FROM n2.txt" && echo "$E" | grep -q "IN_MOVED_TO n3.txt"'
ok "N rename: n3 with its real size, n2 gone" '[ "$(t stat -c %s "$M/notify/n3.txt")" = 8 ] && ! t stat "$M/notify/n2.txt" >/dev/null 2>&1'
rm "$NB/n3.txt"
mark; ctl "backing~deleted~.%notify%n3.txt"; E=$(since); echo "   delete: $E"
ok "N delete: IN_DELETE" 'echo "$E" | grep -q "IN_DELETE n3.txt"'
ok "N delete: gone" '! t stat "$M/notify/n3.txt" >/dev/null 2>&1 && ! t ls "$M/notify" | grep -qx n3.txt'
mkdir "$NB/nd"
mark; ctl "backing~createDir~.%notify%nd"; E=$(since); echo "   mkdir: $E"
ok "N createDir: IN_CREATE|IN_ISDIR" 'echo "$E" | grep -q "IN_CREATE|IN_ISDIR nd"'
rmdir "$NB/nd"
mark; ctl "backing~deleted~.%notify%nd~dir"; E=$(since); echo "   rmdir: $E"
ok "N directory delete: IN_DELETE|IN_ISDIR" 'echo "$E" | grep -q "IN_DELETE|IN_ISDIR nd"'
ok "N no local change events from the touches" '[ "$(grep -c "^EVENT " "$LOG")" = "$EVENTS0" ]'
ok "N backing dir untouched by the touches" '[ "$(ls "$NB" | tr "\n" " ")" = "n1.txt " ] && [ "$(cat "$NB/n1.txt")" = "replaced with longer content" ]'
sleep 1; kill $WATCH $GIOMON 2>/dev/null; wait $WATCH $GIOMON 2>/dev/null
sed "s|$M/notify/||g; s|$M/notify: ||" "$T/gio" | sed "s/^/   gio: /"
ok "N GIO reports created, renamed/moved and deleted" 'grep -q "n1.txt: created" "$T/gio" && grep -q "n3.txt: deleted" "$T/gio" && grep -Eq "n2.txt: (renamed|moved)|n2.txt: deleted" "$T/gio"'

echo "== events seen"
grep '^EVENT' "$LOG"

echo "== stop"
touch "$W/stop"
for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
ok "process exited" '! kill -0 "$PID" 2>/dev/null'
wait "$PID"; RC=$?
ok "exit status 0 (got $RC)" '[ "$RC" = 0 ]'
ok "STOPPED printed" 'grep -q STOPPED "$LOG"'
ok "no mount left" '! grep -q " $M fuse" /proc/mounts'
grep -E '^(DOWNLOADS|STOPPED)' "$LOG"
echo "== unexpected log lines"
grep -vE '^(READY|EVENT|APPLIED|CHANGED|CTL|STUB webUrlOf|STUB reevaluate|STUB (download|createEmpty|action|noteOpen|noteClose [^U])|DOWNLOADS|STOPPED)' "$LOG"
echo "== $PASS passed, $FAIL failed"
trap - EXIT
[ "$FAIL" = 0 ] && rm -rf "$T"
exit $((FAIL != 0))
