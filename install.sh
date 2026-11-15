#!/bin/bash
# Install the Dell VEP1400 / VMware SD-WAN Edge 610 board support.
#
#   sudo ./install.sh              DKMS build + install, enable services
#   sudo ./install.sh --no-start   do not start the services (reboot to use)
#   sudo ./install.sh --no-dkms    build against the running kernel only
#   sudo ./install.sh --initramfs  also put the module into the initramfs
#
# Supported: Debian, Ubuntu, Proxmox VE and VyOS (all systemd + modprobe).

set -euo pipefail

VERSION="2.0.0"
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SRC_DIR="/usr/src/vep1400-$VERSION"
LIB_DIR="/usr/lib/vep1400"
DOC_DIR="/usr/share/doc/vep1400"
UNIT_DIR="/etc/systemd/system"

START=1
USE_DKMS=1
USE_INITRAMFS=0
for arg in "$@"; do
	case "$arg" in
	--no-start) START=0 ;;
	--no-dkms) USE_DKMS=0 ;;
	--initramfs) USE_INITRAMFS=1 ;;
	-h|--help)
		sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "unknown option: $arg" >&2
		exit 1
		;;
	esac
done

[ "$(id -u)" -eq 0 ] || {
	echo "run as root" >&2
	exit 1
}

KVER=$(uname -r)
[ -d "/lib/modules/$KVER/build" ] || {
	echo "ERROR: /lib/modules/$KVER/build is missing." >&2
	echo "       Debian/Ubuntu/PVE: apt install linux-headers-$KVER" >&2
	echo "       VyOS:              apt install linux-headers-$KVER" >&2
	exit 1
}

echo "== installing userspace parts =="
install -d "$LIB_DIR" "$DOC_DIR" "$UNIT_DIR"
install -m 0755 "$HERE/scripts/vep1400-netup.sh" "$LIB_DIR/"
install -m 0755 "$HERE/scripts/vep1400-teardown.sh" "$LIB_DIR/"
install -m 0755 "$HERE/scripts/vep1400-report.sh" "$LIB_DIR/"
install -m 0755 "$HERE/scripts/vep1400-linkdiag.sh" "$LIB_DIR/"
install -m 0644 "$HERE/systemd/vep1400.service" "$UNIT_DIR/"
install -m 0644 "$HERE/systemd/vep1400-net.service" "$UNIT_DIR/"
install -m 0644 "$HERE/modprobe/vep1400.conf" /etc/modprobe.d/
for f in README.md README.zh-CN.md LICENSE; do
	if [ -f "$HERE/$f" ]; then
		install -m 0644 "$HERE/$f" "$DOC_DIR/"
	fi
done

if [ "$USE_DKMS" -eq 1 ] && command -v dkms >/dev/null 2>&1; then
	echo "== building through DKMS =="
	rm -rf "$SRC_DIR"
	install -d "$SRC_DIR"
	cp -a "$HERE/Makefile" "$HERE/dkms.conf" "$HERE/src" "$SRC_DIR/"
	dkms add -m vep1400 -v "$VERSION" 2>/dev/null || true
	dkms build -m vep1400 -v "$VERSION" --force
	dkms install -m vep1400 -v "$VERSION" --force
else
	echo "== building against the running kernel =="
	make -C "$HERE" modules
	install -d "/lib/modules/$KVER/updates/dkms"
	install -m 0644 "$HERE/src/vep1400.ko" "/lib/modules/$KVER/updates/dkms/"
	depmod -a "$KVER"
fi

if [ "$USE_INITRAMFS" -eq 1 ] && [ -d /etc/initramfs-tools ]; then
	echo "== adding the module to the initramfs =="
	install -m 0755 "$HERE/initramfs/hook-vep1400" /etc/initramfs-tools/hooks/vep1400
	install -m 0755 "$HERE/initramfs/local-top-vep1400" "$LIB_DIR/vep1400-initramfs"
	update-initramfs -u
fi

systemctl daemon-reload
systemctl enable vep1400.service vep1400-net.service

if [ "$START" -eq 1 ]; then
	echo "== (re)starting =="
	systemctl restart vep1400.service
	systemctl restart vep1400-net.service || true
	sleep 1
fi

cat <<EOF

Done.

  module   : vep1400 (88E6190 switch, front panel PHYs, LEDs, watchdog, SFP TX)
  services : vep1400.service      loads the module before ixgbe
             vep1400-net.service  creates GE1..GE6, names SFP1/SFP2
  report   : $LIB_DIR/vep1400-report.sh
  portdiag : $LIB_DIR/vep1400-linkdiag.sh <1-6>

Configure addresses on GE1..GE6 (and SFP1/SFP2).  Never configure eno1/eno2,
they are the internal switch uplinks.

Reboot once to verify that everything comes up on its own.
EOF
