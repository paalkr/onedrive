#!/bin/sh
# DB-level test: pins recorded before a resync resolve to the rebuilt database (by id, else by path).
# Usage: run.sh <outdir>
set -e
R="$(cd "$(dirname "$0")/../.." && pwd)"
O="${1:?usage: run.sh <outdir>}"
mkdir -p "$O/J" "$O/obj" "$O/run"
echo pintest > "$O/J/version"
cd "$R"
ldc2 -w -i -J "$O/J" -I src -od="$O/obj" -of="$O/pintest" ondemand/test-pins/pintest.d \
	$(pkg-config --libs-only-l libcurl sqlite3 | sed 's/-l/-L-l/g') -L-ldl
rm -rf "$O/run"/*
"$O/pintest" "$O/run"
