#!/bin/sh
# Build the onedrive-ondemand Debian package from this source tree.
#
# Usage: contrib/ondemand/build-deb.sh [-o OUTPUT_DIR] [-k]
#
#   -o OUTPUT_DIR  where the .deb is written (default: current directory)
#   -k             keep the temporary build directory (path is printed)
#
# The tracked and untracked (not ignored) files of the working tree are
# copied to a temporary directory and built there with
# './configure DC=ldc2 --prefix=/usr ... && make', then staged with
# 'make install DESTDIR=...'. The source tree itself is not modified.
#
# Needs: git, ldc2, libcurl/libsqlite3/libdbus-1/libfuse3 development files,
# dpkg-deb. dpkg-shlibdeps (dpkg-dev) is used for Depends when available.
# Nothing is installed on the build machine.

set -eu
umask 022

OUTDIR=$(pwd)
KEEP=no
while getopts "o:kh" opt; do
	case "$opt" in
	o) OUTDIR=$OPTARG ;;
	k) KEEP=yes ;;
	h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) exit 2 ;;
	esac
done
mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(git -C "$HERE" rev-parse --show-toplevel)

PACKAGE=onedrive-ondemand
ARCH=$(dpkg --print-architecture)

# Version: v2.5.11-151-g5a01d01[-dirty] -> 2.5.11+ondemand.151.g5a01d01[.dirty]
DESCRIBE=$(git -C "$SRC" describe --tags --dirty)
VERSION=$(printf '%s\n' "$DESCRIBE" | sed -E \
	-e 's/^v//' \
	-e 's/^([0-9][0-9.]*)-([0-9]+)-g([0-9a-f]+)/\1+ondemand.\2.g\3/' \
	-e 's/^([0-9][0-9.]*)(-dirty)?$/\1+ondemand\2/' \
	-e 's/-dirty$/.dirty/')
case "$VERSION" in
*[!0-9A-Za-z.+~]*|[!0-9]*) echo "ERROR: cannot derive a Debian version from '$DESCRIBE' (got '$VERSION')" >&2; exit 1 ;;
esac

MAINT_NAME=$(git -C "$SRC" config user.name || echo "Local build")
MAINT_EMAIL=$(git -C "$SRC" config user.email || echo "root@localhost")
SOURCE_DATE_EPOCH=$(git -C "$SRC" log -1 --format=%ct)
export SOURCE_DATE_EPOCH

WORK=$(mktemp -d "${TMPDIR:-/tmp}/onedrive-ondemand-deb.XXXXXX")
cleanup() {
	if [ "$KEEP" = yes ]; then
		echo "Build directory kept: $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

echo "==> Building $PACKAGE $VERSION ($DESCRIBE) in $WORK"
BUILD=$WORK/src
# dpkg-shlibdeps expects the staged tree at debian/<package>
STAGE=$WORK/pkg/debian/$PACKAGE
mkdir -p "$BUILD" "$STAGE"
(cd "$SRC" && git ls-files -z --cached --others --exclude-standard | tar --null -T - --ignore-failed-read -cf -) | (cd "$BUILD" && tar -xf -)

cd "$BUILD"
./configure DC=ldc2 \
	--prefix=/usr \
	--sysconfdir=/etc \
	--mandir=/usr/share/man \
	--with-systemdsystemunitdir=/usr/lib/systemd/system \
	--with-systemduserunitdir=/usr/lib/systemd/user \
	--enable-completions \
	--with-bash-completion-dir=/usr/share/bash-completion/completions \
	--with-zsh-completion-dir=/usr/share/zsh/vendor-completions \
	--with-fish-completion-dir=/usr/share/fish/vendor_completions.d
# There is no .git in the copy; 'version' sets what 'onedrive --version' reports
make version="$DESCRIBE"

DOCDIR=/usr/share/doc/$PACKAGE
make install DESTDIR="$STAGE" docdir="$DOCDIR" version="$DESCRIBE"

# --- on-demand additions ---
install -m 0755 "$BUILD/contrib/ondemand/onedrive-ondemand-setup" "$STAGE/usr/bin/onedrive-ondemand-setup"
install -m 0755 "$BUILD/contrib/ondemand/onedrive-ondemand-unmount" "$STAGE/usr/bin/onedrive-ondemand-unmount"
install -m 0644 "$BUILD/contrib/ondemand/systemd/onedrive-ondemand.service" "$STAGE/usr/lib/systemd/user/onedrive-ondemand.service"
install -m 0644 "$BUILD/contrib/ondemand/systemd/onedrive-ondemand@.service" "$STAGE/usr/lib/systemd/user/onedrive-ondemand@.service"
mkdir -p "$STAGE/usr/share/nautilus-python/extensions"
install -m 0644 "$BUILD/contrib/nautilus/onedrive-ondemand.py" "$STAGE/usr/share/nautilus-python/extensions/onedrive-ondemand.py"
install -m 0644 "$BUILD/contrib/ondemand/README.md" "$STAGE$DOCDIR/README.ondemand.md"
for page in onedrive-ondemand-setup onedrive-ondemand-unmount; do
	install -m 0644 "$BUILD/contrib/ondemand/man/$page.1" "$STAGE/usr/share/man/man1/$page.1"
	gzip -9n "$STAGE/usr/share/man/man1/$page.1"
done

# --- Debian policy fixes on the staged tree ---
strip --strip-unneeded --remove-section=.comment --remove-section=.note "$STAGE/usr/bin/onedrive"
gzip -9n "$STAGE/usr/share/man/man1/onedrive.1"
# The licence is referenced from the copyright file instead
rm -f "$STAGE$DOCDIR/LICENSE"
mv "$STAGE$DOCDIR/changelog.md" "$STAGE$DOCDIR/changelog"
gzip -9n "$STAGE$DOCDIR/changelog"
cat > "$STAGE$DOCDIR/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: onedrive
Source: https://github.com/abraunegg/onedrive
Comment: Local build of a fork that adds Files On-Demand.

Files: *
Copyright: abraunegg and contributors
License: GPL-3
 On Debian systems, the complete text of the GNU General Public License
 version 3 can be found in /usr/share/common-licenses/GPL-3.

Files: src/arsd/*
Copyright: 2008-2023 Adam D. Ruppe
License: BSL-1.0
 Boost Software License - Version 1.0 - August 17th, 2003
 .
 Permission is hereby granted, free of charge, to any person or organization
 obtaining a copy of the software and accompanying documentation covered by
 this license (the "Software") to use, reproduce, display, distribute,
 execute, and transmit the Software, and to prepare derivative works of the
 Software, and to permit third-parties to whom the Software is furnished to
 do so, all subject to the following:
 .
 The copyright notices in the Software and this entire statement, including
 the above license grant, this restriction and the following disclaimer,
 must be included in all copies of the Software, in whole or in part, and
 all derivative works of the Software, unless such copies or derivative
 works are solely in the form of machine-executable object code generated by
 a source language processor.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 DEALINGS IN THE SOFTWARE.
EOF
{
	printf '%s (%s) unstable; urgency=medium\n\n' "$PACKAGE" "$VERSION"
	printf '  * Local build of %s.\n\n' "$DESCRIBE"
	printf ' -- %s <%s>  %s\n' "$MAINT_NAME" "$MAINT_EMAIL" "$(LC_ALL=C date -u -R -d "@$SOURCE_DATE_EPOCH")"
} | gzip -9n > "$STAGE$DOCDIR/changelog.Debian.gz"
find "$STAGE" -name __pycache__ -prune -exec rm -rf {} +
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f ! -perm -u+x -exec chmod 0644 {} +
find "$STAGE" -type f -perm -u+x -exec chmod 0755 {} +

# --- Depends ---
# fusermount3 mounts on behalf of the user; python3 runs onedrive-ondemand-setup
EXTRA_DEPS="fuse3, python3"
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
	printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$PACKAGE" "$PACKAGE" > "$WORK/pkg/debian/control"
	SHLIBS=$(cd "$WORK/pkg" && dpkg-shlibdeps -O "debian/$PACKAGE/usr/bin/onedrive" | sed -n 's/^shlibs:Depends=//p')
else
	# Fallback: map each linked library to the package that ships it
	SHLIBS=$(ldd "$STAGE/usr/bin/onedrive" | awk '/=> \//{print $3}' | while read -r lib; do
		dpkg -S "$(readlink -f "$lib")" 2>/dev/null | head -1 | cut -d: -f1
	done | sort -u | paste -sd, | sed 's/,/, /g')
fi
DEPENDS="$SHLIBS, $EXTRA_DEPS"

INSTALLED_SIZE=$(du -sk --apparent-size "$STAGE" | cut -f1)
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINT_NAME <$MAINT_EMAIL>
Installed-Size: $INSTALLED_SIZE
Depends: $DEPENDS
Recommends: python3-nautilus, libgdk-pixbuf2.0-bin, zenity, libnotify-bin
Conflicts: onedrive
Replaces: onedrive
Provides: onedrive
Section: net
Priority: optional
Homepage: https://github.com/abraunegg/onedrive
Description: OneDrive client for Linux with Files On-Demand (local fork)
 A build of the abraunegg/onedrive client with Files On-Demand: the
 configured sync_dir is presented as a FUSE mount, files are downloaded
 when they are first opened, and can be pinned or freed per file or folder.
 .
 Includes the onedrive-ondemand-setup helper for per-user profiles,
 systemd user units (onedrive-ondemand.service and
 onedrive-ondemand@.service) and a Nautilus extension for the file manager.
 .
 Replaces the distribution's onedrive package; /usr/bin/onedrive is this
 client. User configuration and data are never touched by the package.
EOF
echo /etc/logrotate.d/onedrive > "$STAGE/DEBIAN/conffiles"
(cd "$STAGE" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 md5sum) > "$STAGE/DEBIAN/md5sums"
chmod 0644 "$STAGE/DEBIAN/control" "$STAGE/DEBIAN/conffiles" "$STAGE/DEBIAN/md5sums"

DEB=$OUTDIR/${PACKAGE}_${VERSION}_${ARCH}.deb
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB"
echo "==> $DEB"
