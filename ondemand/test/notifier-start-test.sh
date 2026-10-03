#!/bin/bash
# The file manager replay thread reports its thread id late: notifications
# must stay off (fail closed) rather than run replays as real operations.
# Usage: notifier-start-test.sh <odtest binary>
set -u
BIN="$(realpath "${1:?usage: notifier-start-test.sh <odtest binary>}")"
T="$(mktemp -d "${TMPDIR:-/tmp}/odnstart.XXXXXX")"
W="$T/work"; M="$T/mnt"; LOG="$T/odtest.log"
mkdir -p "$W/ctl" "$M"
PID=
cleanup() {
	touch "$W/stop"
	for i in $(seq 1 50); do [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
	[ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
	grep -q " $M fuse" /proc/mounts && fusermount3 -u -z "$M"
}
trap cleanup EXIT
ODTEST_NOTIFIER_START_DELAY=2000 timeout 120 "$BIN" "$W" "$M" 0 > "$LOG" 2>&1 &
PID=$!
for i in $(seq 1 100); do grep -q READY "$LOG" && break; sleep 0.1; done
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
ctl() {
	local n; n=$(grep -c "^CTL $1\$" "$LOG")
	touch "$W/ctl/$1"
	for i in $(seq 1 30); do [ "$(grep -c "^CTL $1\$" "$LOG")" -gt "$n" ] && return; sleep 0.1; done
}
B="/proc/$(awk '/^PHYSICAL/{print $2; exit}' "$LOG")/fd/$(awk '/^PHYSICAL/{print $3; exit}' "$LOG")"
ok "N1 mounted" 'grep -q READY "$LOG"'
# Engine downloads reported, then gone again, and a freed file reported
ctl "burst~50"
t() { timeout 10 "$@"; }
t python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.onedrive.action", b"free")' "$M/local.txt" 2>/dev/null
sleep 3   # past the replay thread's late start
for i in $(seq 1 30); do grep -q "notification thread did not start" "$LOG" && break; sleep 0.1; done
ok "N1 late replay thread: warning logged, notifications off" 'grep -q "WARNING: On-demand: the file manager notification thread did not start" "$LOG"'
ok "N1 no backing file created" '[ -z "$(ls -A "$B/notify/burst")" ]'
ok "N1 no local change event" '! grep -q "^EVENT " "$LOG"'
ok "N1 freed file still online-only, not recreated" '[ ! -e "$B/local.txt" ]'
touch "$W/stop"
for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
ok "N1 clean stop, no mount left" '! kill -0 "$PID" 2>/dev/null && ! grep -q " $M fuse" /proc/mounts'
echo "== $PASS passed, $FAIL failed"
trap - EXIT
[ "$FAIL" = 0 ] && rm -rf "$T"
exit $((FAIL != 0))
