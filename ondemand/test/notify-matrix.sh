#!/bin/bash
# Which FUSE kernel notification makes an inotify watcher on a mounted
# directory see a change made to the backing dir behind the mount's back?
# Mounts odtest under $TMPDIR, watches <mnt>/notify, changes <backing>/notify
# directly, sends one notification and prints the events that arrived.
# Usage: notify-matrix.sh <odtest binary>
set -u
BIN="$(realpath "${1:?usage: notify-matrix.sh <odtest binary>}")"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/odnotify.XXXXXX")"
W="$T/work"; M="$T/mnt"; LOG="$T/odtest.log"; EV="$T/events"
mkdir -p "$W/ctl" "$M"
PID=; WPID=
cleanup() {
	[ -n "$WPID" ] && kill "$WPID" 2>/dev/null
	touch "$W/stop"
	for i in $(seq 1 50); do [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
	[ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
	grep -q " $M fuse" /proc/mounts && fusermount3 -u -z "$M"
	rm -rf "$T"
}
trap cleanup EXIT
timeout 300 "$BIN" "$W" "$M" 0 > "$LOG" 2>&1 &
PID=$!
for i in $(seq 1 50); do grep -q READY "$LOG" && break; sleep 0.1; done
B="$W/backing/notify"
ctl() {
	local n; n=$(grep -c "^CTL $1\$" "$LOG")
	touch "$W/ctl/$1"
	for i in $(seq 1 30); do [ "$(grep -c "^CTL $1\$" "$LOG")" -gt "$n" ] && return; sleep 0.1; done
}
timeout 300 python3 "$HERE/inotify-watch.py" "$M/notify" > "$EV" 2>&1 &
WPID=$!
for i in $(seq 1 30); do grep -q WATCHING "$EV" && break; sleep 0.1; done

# run <scenario> <mode> <name>: prints the events after the notification
run() {
	local scenario=$1 mode=$2 name=$3 before
	case $scenario in
		create) ls "$M/notify" >/dev/null ;;
		create-after-negative-lookup) stat "$M/notify/$name" >/dev/null 2>&1 ;;
		modify|delete) echo old > "$B/$name"; stat "$M/notify/$name" >/dev/null; ctl "ino~%notify%$name" ;;
	esac
	sleep 0.3
	before=$(wc -l < "$EV")
	case $scenario in
		create*) echo new > "$B/$name" ;;
		modify) echo more >> "$B/$name" ;;
		delete) rm "$B/$name" ;;
	esac
	sleep 0.3
	local quiet=$(( $(wc -l < "$EV") - before ))
	ctl "exp~$mode~%notify%$name"
	sleep 0.5
	local rc; rc=$(grep "^EXP $mode /notify/$name " "$LOG" | tail -1 | sed 's/.* rc=//')
	local got; got=$(tail -n +$((before + 1)) "$EV" | tr '\n' ' ')
	local detail; detail=$(grep "^EXP $mode /notify/$name " "$LOG" | tail -1 | grep -o "parent=[0-9]* ino=[0-9]*")
	printf '%-30s %-20s rc=%-4s %-22s events: %s\n' "$scenario" "$mode" "$rc" "$detail" "${got:-none}"
	[ "$quiet" = 0 ] || echo "   ($quiet events before the notification)"
}

echo "kernel $(uname -r), libfuse $(pkg-config --modversion fuse3)"
# Control: changes made through the mount must reach the watcher
before=$(wc -l < "$EV")
echo x > "$M/notify/control.txt"; echo y >> "$M/notify/control.txt"; rm "$M/notify/control.txt"
sleep 0.5
printf '%-51s events: %s\n' "control (through the mount)" "$(tail -n +$((before + 1)) "$EV" | tr '\n' ' ')"
n=0
for scenario in create create-after-negative-lookup modify delete; do
	for mode in inval_entry delete inval_inode inval_inode_dir invalidate_path invalidate_path_dir; do
		n=$((n + 1))
		run "$scenario" "$mode" "f$n.txt"
	done
done
