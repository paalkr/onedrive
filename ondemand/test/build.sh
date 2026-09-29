#!/bin/sh
# Builds ondemand/test/odtest: src/ondemand.d, the fuse bindings and the real
# itemdb.d against the stub hydration module. Usage: build.sh <outdir>
set -e
R="$(cd "$(dirname "$0")/../.." && pwd)"
O="${1:?usage: build.sh <outdir>}"
mkdir -p "$O/obj" "$O/J"
echo odtest > "$O/J/version"
cd "$R"
SRCS=$(ls src/*.d | grep -v '^src/main.d$')
ldc2 -w -g -oq -J "$O/J" -I src -od="$O/obj" -of="$O/odtest" \
	ondemand/test/odtest.d ondemand/test/stub/hydration.d $SRCS src/arsd/cgi.d \
	src/c/fuse/common.d src/c/fuse/fuse.d src/fused/fuse.d \
	$(pkg-config --libs-only-l fuse3 libcurl sqlite3 dbus-1 | sed 's/-l/-L-l/g') -L-ldl
