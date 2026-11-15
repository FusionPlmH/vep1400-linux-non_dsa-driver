#!/bin/bash
# vep1400 bootstrap for a self-hosted mirror.
#
# Upload this file next to the source archive on your own web space, e.g.
#   https://neodev.team/get.sh
#   https://neodev.team/vep1400-linux-non_dsa-driver.tar.gz   (preferred)
#   https://neodev.team/vep1400-linux-non_dsa-driver.zip      (also works)
#
# Then the mirror one-liner is simply:
#
#   curl -fsSL https://neodev.team/get.sh | sudo bash
#
# Why a separate script: the upstream get.sh downloads the source archive from
# github.com, so hosting get.sh alone would not help anyone whose GitHub access
# is blocked or slow. This copy never touches github.com.
#
# It tries .tar.gz first and falls back to .zip. Both unpack with tools the
# target systems already have, but tar is Essential in Debian/Ubuntu/PVE/VyOS
# while unzip is only Priority: optional - so the tarball is the safer upload.
#
# Options are passed straight through to install.sh:
#   curl -fsSL https://neodev.team/get.sh | sudo bash -s -- --userspace
#   curl -fsSL https://neodev.team/get.sh | sudo bash -s -- --initramfs
#
# VEP1400_TARBALL overrides the archive URL completely.

set -euo pipefail

BASE=${VEP1400_BASE:-https://neodev.team}
NAME=vep1400-linux-non_dsa-driver

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}

fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$2" "$1" 2>/dev/null
	else
		echo "ERROR: curl or wget is required" >&2
		exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -n "${VEP1400_TARBALL:-}" ]; then
	CANDIDATES=("$VEP1400_TARBALL")
else
	CANDIDATES=("$BASE/$NAME.tar.gz" "$BASE/$NAME.zip")
fi

ARCHIVE=""
for url in "${CANDIDATES[@]}"; do
	echo "== downloading $url"
	if fetch "$url" "$TMP/src.archive"; then
		ARCHIVE=$url
		break
	fi
	echo "   not available"
done
[ -n "$ARCHIVE" ] || {
	echo "ERROR: no archive found on the mirror" >&2
	exit 1
}

mkdir -p "$TMP/src"
echo "== unpacking"
case "$ARCHIVE" in
*.zip)
	command -v unzip >/dev/null 2>&1 || {
		echo "ERROR: the mirror only has a .zip and unzip is not installed." >&2
		echo "       apt install unzip   (or ask for a .tar.gz instead)" >&2
		exit 1
	}
	unzip -q "$TMP/src.archive" -d "$TMP/src"
	;;
*)
	command -v tar >/dev/null 2>&1 || {
		echo "ERROR: tar is missing, which should not happen on Debian/Ubuntu/PVE/VyOS" >&2
		exit 1
	}
	tar -xzf "$TMP/src.archive" -C "$TMP/src"
	;;
esac

DIR=$(find "$TMP/src" -mindepth 1 -maxdepth 3 -name install.sh -printf '%h\n' | head -1)
[ -n "$DIR" ] || {
	echo "ERROR: the archive does not contain install.sh" >&2
	exit 1
}
chmod +x "$DIR/install.sh" "$DIR/uninstall.sh" "$DIR"/scripts/*.sh "$DIR"/scripts/*.py 2>/dev/null || true

bash "$DIR/install.sh" "$@"
