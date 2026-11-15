#!/bin/bash
# vep1400 bootstrap for a self-hosted mirror (.tar.gz only).
#
# Upload this file next to the tarball on your own web space, e.g.
#   https://neodev.team/get.sh
#   https://neodev.team/vep1400-linux-non_dsa-driver.tar.gz
#
# Then the mirror one-liner is simply:
#
#   curl -fsSL https://neodev.team/get.sh | sudo bash
#
# Why a separate script: the upstream get.sh downloads the source archive from
# github.com, so hosting get.sh alone would not help anyone whose GitHub access
# is blocked or slow. This copy never touches github.com.
#
# .tar.gz only, on purpose: tar is Essential in Debian/Ubuntu/PVE/VyOS, while
# unzip is Priority: optional and often missing on a minimal install.
#
# Options are passed straight through to install.sh:
#   curl -fsSL https://neodev.team/get.sh | sudo bash -s -- --userspace
#   curl -fsSL https://neodev.team/get.sh | sudo bash -s -- --initramfs
#
# VEP1400_TARBALL overrides the archive URL completely.

set -euo pipefail

BASE=${VEP1400_BASE:-https://neodev.team}
URL=${VEP1400_TARBALL:-$BASE/vep1400-linux-non_dsa-driver.tar.gz}

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== downloading $URL"
if command -v curl >/dev/null 2>&1; then
	curl -fsSL "$URL" -o "$TMP/src.tar.gz"
elif command -v wget >/dev/null 2>&1; then
	wget -qO "$TMP/src.tar.gz" "$URL"
else
	echo "ERROR: curl or wget is required" >&2
	exit 1
fi

echo "== unpacking"
mkdir -p "$TMP/src"
tar -xzf "$TMP/src.tar.gz" -C "$TMP/src"

DIR=$(find "$TMP/src" -mindepth 1 -maxdepth 3 -name install.sh -printf '%h\n' | head -1)
[ -n "$DIR" ] || {
	echo "ERROR: the archive does not contain install.sh" >&2
	exit 1
}
chmod +x "$DIR/install.sh" "$DIR/uninstall.sh" "$DIR"/scripts/*.sh "$DIR"/scripts/*.py 2>/dev/null || true

bash "$DIR/install.sh" "$@"
