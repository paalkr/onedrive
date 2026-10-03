#!/bin/bash
# Client-level tests of the physical sync_dir layout that need no account: stale and live mounts at
# start, migration from the previous layout's backing directory, a moved sync_dir, refusals, and the
# crash-between-staging-and-rename recovery. Each client run has a fake refresh token, so it stops
# at authentication (exit 1) after the on-demand preparation under test. Mounts only under $TMPDIR.
# Usage, from the repository root after ./configure DC=ldc2 && make (which writes ./version):
#   run.sh <onedrive binary> <odtest binary> [<dir with prebuilt mkdb and stagingtest>]
# Without the third argument the helpers are built into a temporary directory with:
#   ldc2 -w -i -J . -I src -od=<dir>/obj -of=<dir>/<helper> ondemand/test-physical/<helper>.d \
#     $(pkg-config --libs-only-l libcurl sqlite3 dbus-1 | sed 's/-l/-L-l/g') -L-ldl
set -u
BIN="$(realpath "$1")"; ODT="$(realpath "$2")"
T="$(mktemp -d "${TMPDIR:-/tmp}/odphys.XXXXXX")"
case "$(cd "$T" && git rev-parse --is-inside-work-tree 2>/dev/null)" in true) echo "inside a git work tree, refusing"; exit 2;; esac
if [ $# -ge 3 ]; then
	H="$(realpath "$3")"
else
	[ -f version ] && [ -d src ] || { echo "run from the repository root after make (needs ./version and src/)"; exit 2; }
	H="$T/build"; mkdir -p "$H"
	for helper in mkdb stagingtest; do
		ldc2 -w -i -J . -I src -od="$H/obj" -of="$H/$helper" "ondemand/test-physical/$helper.d" \
			$(pkg-config --libs-only-l libcurl sqlite3 dbus-1 | sed 's/-l/-L-l/g') -L-ldl || { echo "building $helper failed"; exit 2; }
	done
fi
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
mounted() { grep -q " $1 fuse" /proc/mounts; }
cleanup() { for m in $(grep " $T/" /proc/mounts | awk '{print $2}'); do fusermount3 -u -z "$m"; done; }
trap cleanup EXIT
profile() {   # profile <confdir> <sync_dir>: config and a fake refresh token
	mkdir -p "$1"
	printf 'sync_dir = "%s"\n' "$2" > "$1/config"
	echo "invalid-token" > "$1/refresh_token"; chmod 600 "$1/refresh_token"
}
client() {    # client <confdir>: runs until authentication fails; log in <confdir>.log, exit code in <confdir>.rc
	BROWSER=/bin/true timeout 60 "$BIN" --confdir "$1" --monitor --on-demand </dev/null > "$1.log" 2>&1
	echo $? > "$1.rc"
}
rows() { python3 -c 'import sqlite3,sys; print(sorted(sqlite3.connect(sys.argv[1]).execute("select driveId,id,name,hydration from item").fetchall()))' "$1"; }
odtest() {    # odtest <work> <mnt>: FUSE harness mounted on <mnt>
	mkdir -p "$1/ctl" "$2"
	"$ODT" "$1" "$2" 0 > "$1.log" 2>&1 &
	ODPID=$!
	for i in $(seq 1 50); do mounted "$2" && break; sleep 0.1; done
}

echo "== stale mount at start"
C="$T/stale"; S="$T/stale-sync"; profile "$C" "$S"
odtest "$T/stale-w" "$S"; kill -9 $ODPID; wait $ODPID 2>/dev/null
ok "T1 a dead mount is left behind" 'mounted "$S" && ! stat "$S" >/dev/null 2>&1'
client "$C"
ok "T1 stale mount detected and unmounted" 'grep -q "stale mount" "$C.log" && ! mounted "$S"'
ok "T1 the client continued to authentication (exit 1 from the fake token)" '[ "$(cat "$C.rc")" = 1 ] && grep -q "auth token" "$C.log"'

echo "== live mount at start"
C="$T/live"; S="$T/live-sync"; profile "$C" "$S"
odtest "$T/live-w" "$S"
client "$C"
ok "T2 live mount: refused, exit 1" '[ "$(cat "$C.rc")" = 1 ] && grep -q "already mounted by a running on-demand client" "$C.log"'
ok "T2 the other mount was left alone" 'mounted "$S" && ls "$S" | grep -q docs'
touch "$T/live-w/stop"; wait $ODPID 2>/dev/null

echo "== migration from the previous layout's backing directory"
C="$T/mig"; S="$T/mig-sync"; profile "$C" "$S"
OLD="$C/ondemand/backing"
mkdir -p "$OLD/docs" "$S" "$C/ondemand/.backing.staging"
echo "hydrated" > "$OLD/docs/hydrated.txt"; echo "pinned" > "$OLD/pinned.txt"; echo "plain" > "$OLD/plain.txt"
echo "junk" > "$C/ondemand/.backing.staging/x"
"$H/mkdb" "$C/items.sqlite3"
printf '%s' "$OLD" > "$C/items.sqlite3.ondemand"
BEFORE="$(rows "$C/items.sqlite3")"
client "$C"
ok "T3 files moved into sync_dir by rename" '[ "$(cat "$S/docs/hydrated.txt")" = hydrated ] && [ "$(cat "$S/pinned.txt")" = pinned ] && [ "$(cat "$S/plain.txt")" = plain ]'
ok "T3 old backing dir and staging leftovers gone" '[ ! -e "$OLD" ] && [ ! -e "$C/ondemand/.backing.staging" ]'
ok "T3 marker records sync_dir" '[ "$(cat "$C/items.sqlite3.ondemand")" = "$S" ]'
ok "T3 database rows and hydration states unchanged" '[ "$(rows "$C/items.sqlite3")" = "$BEFORE" ]'
ok "T3 logged as a move without transfers" 'grep -q "moved the hydrated files from $OLD" "$C.log"'

echo "== sync_dir changed: the physical directory moves"
C="$T/move"; S1="$T/move-old"; S2="$T/sub/move-new"; profile "$C" "$S2"
mkdir -p "$S1/docs"; echo "keep" > "$S1/docs/a.txt"
"$H/mkdb" "$C/items.sqlite3"
printf '%s' "$S1" > "$C/items.sqlite3.ondemand"
client "$C"
ok "T4 sync_dir renamed to the new path" '[ "$(cat "$S2/docs/a.txt")" = keep ] && [ ! -e "$S1" ] && [ "$(cat "$C/items.sqlite3.ondemand")" = "$S2" ]'

echo "== refusals"
C="$T/conflict"; S1="$T/conflict-old"; S2="$T/conflict-new"; profile "$C" "$S2"
mkdir -p "$S1" "$S2"; echo "a" > "$S1/a.txt"; echo "b" > "$S2/b.txt"
printf '%s' "$S1" > "$C/items.sqlite3.ondemand"
client "$C"
ok "T5 non-empty sync_dir: refused, nothing moved or overwritten" '[ "$(cat "$C.rc")" = 1 ] && grep -q "already contains files" "$C.log" && [ -f "$S1/a.txt" ] && [ "$(ls "$S2")" = b.txt ]'
if [ -d /dev/shm ] && [ "$(stat -c %d /dev/shm)" != "$(stat -c %d "$T")" ]; then
	C="$T/xfs"; S1="/dev/shm/odphys-$$"; S2="$T/xfs-new"; profile "$C" "$S2"
	mkdir -p "$S1"; echo "x" > "$S1/x.txt"
	printf '%s' "$S1" > "$C/items.sqlite3.ondemand"
	client "$C"
	ok "T6 other filesystem: refused, nothing moved" '[ "$(cat "$C.rc")" = 1 ] && grep -q "same filesystem" "$C.log" && [ -f "$S1/x.txt" ] && [ ! -e "$S2/x.txt" ]'
	rm -rf "$S1"
else
	echo "SKIP T6 (no second filesystem at /dev/shm)"
fi

echo "== crash between staging and rename"
"$H/stagingtest" "$T/staging" | grep -E "^(PASS|FAIL)" > "$T/staging.out"
while read -r line; do echo "$line"; case "$line" in PASS*) PASS=$((PASS+1));; FAIL*) FAIL=$((FAIL+1));; esac; done < "$T/staging.out"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && rm -rf "$T"
[ "$FAIL" = 0 ]
