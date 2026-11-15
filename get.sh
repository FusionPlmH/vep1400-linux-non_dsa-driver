#!/bin/bash
# Download and install the vep1400 driver without git.
#
#   curl -fsSL https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh | sudo bash
#   curl -fsSL .../get.sh | sudo bash -s -- --initramfs
#
# Mirrors and proxies (a .tar.gz or a .zip both work):
#   VEP1400_BASE     repository base URL
#   VEP1400_REF      branch to download (default main)
#   VEP1400_TARBALL  full archive URL, overrides both
#
#   curl -fsSL .../get.sh | sudo VEP1400_TARBALL=https://example.com/vep1400.zip bash

set -euo pipefail

BASE=${VEP1400_BASE:-https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver}
REF=${VEP1400_REF:-main}
URL=${VEP1400_TARBALL:-$BASE/archive/refs/heads/$REF.tar.gz}

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== downloading $URL"
if command -v curl >/dev/null 2>&1; then
	curl -fsSL "$URL" -o "$TMP/src.archive"
elif command -v wget >/dev/null 2>&1; then
	wget -qO "$TMP/src.archive" "$URL"
else
	echo "ERROR: curl or wget is required" >&2
	exit 1
fi

mkdir -p "$TMP/src"
echo "== unpacking"
case "$URL" in
*.zip)
	command -v unzip >/dev/null 2>&1 || {
		echo "ERROR: unzip is required for a .zip archive" >&2
		exit 1
	}
	unzip -q "$TMP/src.archive" -d "$TMP/src"
	;;
*)
	tar -xzf "$TMP/src.archive" -C "$TMP/src"
	;;
esac

DIR=$(find "$TMP/src" -mindepth 1 -maxdepth 3 -name install.sh -printf '%h\n' | head -1)
[ -n "$DIR" ] || {
	echo "ERROR: the archive does not contain install.sh" >&2
	exit 1
}
chmod +x "$DIR/install.sh" "$DIR/uninstall.sh" "$DIR"/scripts/*.sh 2>/dev/null || true

bash "$DIR/install.sh" "$@"
