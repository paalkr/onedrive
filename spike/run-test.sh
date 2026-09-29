#!/bin/sh
# Mounts hellofs, exercises it, and always unmounts. Usage: run-test.sh [-s] [ncat]
S="$(cd "$(dirname "$0")" && pwd)"
M="$S/mnt"; LOG="$S/hellofs$1.log"; N="${2:-20}"
mkdir -p "$M"
( ulimit -c unlimited; timeout 60 "$S/hellofs" "$M" $1 > "$LOG" 2>&1; echo "hellofs exit=$?" >> "$LOG" ) &
trap 'fusermount3 -u "$M" 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do grep -q " $M fuse" /proc/mounts && break; sleep 0.2; done
P=$(pgrep -x hellofs)
echo "== ls -la"; timeout 5 ls -la "$M" "$M/hello"
echo "== stat"; timeout 5 stat "$M/hello/world.txt"
echo "== cat | head -2"; timeout 5 cat "$M/hello/world.txt" | head -2
echo "== $N concurrent cats (md5 counts)"
for i in $(seq 1 "$N"); do (timeout 10 cat "$M/hello/world.txt" | md5sum) & done | sort | uniq -c
wait_cats() { while pgrep -x cat -P $$ >/dev/null 2>&1; do sleep 0.1; done; }
sleep 0.5
echo "== hellofs threads: $(ls /proc/$P/task 2>/dev/null | wc -l)"
echo "== unmount"; fusermount3 -u "$M"; trap - EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x hellofs >/dev/null || break; sleep 0.3; done
echo "== still mounted: $(grep -c " $M fuse" /proc/mounts)"
echo "== log (non-open lines)"; grep -v "open(" "$LOG"
echo "== open() log lines: $(grep -c 'open(' "$LOG")"; grep "open(" "$LOG" | head -3
