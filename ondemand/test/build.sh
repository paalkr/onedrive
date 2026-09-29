#!/bin/sh
# Builds ondemand/test/odtest: src/ondemand.d, the fuse bindings and the real
# itemdb.d against the stub hydration module. Usage: build.sh <outdir>
set -e
R="$(cd "$(dirname "$0")/../.." && pwd)"
O="${1:?usage: build.sh <outdir>}"
mkdir -p "$O/obj" "$O/J"
echo odtest > "$O/J/version"
cd "$R"
# -i compiles only the modules odtest imports; the stub dir comes first so
# "import hydration" finds the stub, not src/hydration.d
ldc2 -w -g -oq -i -J "$O/J" -I ondemand/test/stub -I src -od="$O/obj" -of="$O/odtest" \
	ondemand/test/odtest.d \
	$(pkg-config --libs-only-l fuse3 libcurl sqlite3 dbus-1 | sed 's/-l/-L-l/g') -L-ldl
