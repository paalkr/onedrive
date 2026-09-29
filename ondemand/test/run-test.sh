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
downloads() { grep -c "^STUB download $1\$" "$LOG"; }
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
ok "readdir lists DB children and backing entries" '[ "$(t ls "$M" | tr "\n" " ")" = "docs emptydir local.txt write-me.txt " ]'
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
grep -vE '^(READY|EVENT|STUB download|DOWNLOADS|STOPPED)' "$LOG"
echo "== $PASS passed, $FAIL failed"
trap - EXIT
[ "$FAIL" = 0 ] && rm -rf "$T"
exit $((FAIL != 0))
