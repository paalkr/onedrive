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
ok "readdir lists DB children and backing entries" '[ "$(t ls "$M" | tr "\n" " ")" = "apply docs emptydir hold local.txt shared write-me.txt " ]'
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
ok "state xattr absent for item not in DB" 'xget "$M/new.txt" user.onedrive.state | grep -q "No data available"'

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
grep -vE '^(READY|EVENT|APPLIED|STUB download|STUB createEmpty|DOWNLOADS|STOPPED)' "$LOG"
echo "== $PASS passed, $FAIL failed"
trap - EXIT
[ "$FAIL" = 0 ] && rm -rf "$T"
exit $((FAIL != 0))
