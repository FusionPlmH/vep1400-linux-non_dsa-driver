#!/bin/bash
# Dell VEP1400 / VMware SD-WAN Edge 610 board support.
#
# Two implementations, pick one and stay with it:
#
#   sudo ./install.sh               kernel module (recommended on Debian,
#                                   Ubuntu and Proxmox VE: DKMS survives
#                                   kernel upgrades, runs before igb/ixgbe)
#   sudo ./install.sh --userspace   userspace bring-up (no compiler, no kernel
#                                   headers, no kernel taint)
#
# Options:
#   --no-start     install and enable, do not start now (reboot to use)
#   --no-dkms      module mode: build for the running kernel only
#   --initramfs    module mode: also load the module from the initramfs
#   --force        replace a previously installed version of the other mode
#
# VyOS: use ./vyos/setup.sh instead (userspace only, it has no compiler).

set -euo pipefail

VERSION="2.0.0"
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SRC_DIR="/usr/src/vep1400-$VERSION"
LIB_DIR="/usr/lib/vep1400"
DOC_DIR="/usr/share/doc/vep1400"
UNIT_DIR="/etc/systemd/system"
TOOL="$LIB_DIR/vep1400-userspace.py"

MODE="module"
START=1
USE_DKMS=1
USE_INITRAMFS=0
FORCE=0
for arg in "$@"; do
	case "$arg" in
	--userspace) MODE="userspace" ;;
	--module) MODE="module" ;;
	--no-start) START=0 ;;
	--no-dkms) USE_DKMS=0 ;;
	--initramfs) USE_INITRAMFS=1 ;;
	--force) FORCE=1 ;;
	-h | --help)
		sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
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

if [ -d /opt/vyatta ]; then
	if [ "$MODE" = module ]; then
		echo "this looks like VyOS: it has no compiler and no kernel headers," >&2
		echo "so the module cannot be built there. Use ./vyos/setup.sh instead." >&2
		exit 1
	fi
	cat >&2 <<'EOF'
WARNING: this looks like VyOS.
         --userspace works here, but /usr does not survive an image upgrade.
         Prefer ./vyos/setup.sh, which keeps the tool in /config instead.
EOF
fi

if [ "$MODE" = module ]; then
	KVER=$(uname -r)
	[ -d "/lib/modules/$KVER/build" ] || {
		echo "ERROR: /lib/modules/$KVER/build is missing." >&2
		echo "       apt install linux-headers-$KVER   (pve-headers on PVE)" >&2
		echo "       or install the userspace variant:  $0 --userspace" >&2
		exit 1
	}
else
	command -v python3 >/dev/null 2>&1 || {
		echo "ERROR: --userspace needs python3" >&2
		exit 1
	}
	[ -r /dev/mem ] || {
		echo "ERROR: --userspace needs a readable /dev/mem" >&2
		echo "       (CONFIG_DEVMEM=y, CONFIG_STRICT_DEVMEM allows MMIO)" >&2
		exit 1
	}
fi

# ---------------------------------------------------------------------------
# do not let the two variants coexist

installed_mode() {
	if [ -f "$UNIT_DIR/vep1400.service" ] &&
		grep -q 'vep1400-userspace.py' "$UNIT_DIR/vep1400.service" 2>/dev/null; then
		echo userspace
	elif [ -f "$UNIT_DIR/vep1400.service" ]; then
		echo module
	fi
}

PREV=$(installed_mode)
if [ -n "$PREV" ] && [ "$PREV" != "$MODE" ]; then
	if [ "$FORCE" -eq 0 ]; then
		cat >&2 <<EOF
ERROR: the $PREV variant is already installed.
       Run ./uninstall.sh first, or add --force to replace it in place.
       (Mixing the two is not supported: both would drive the same switch.)
EOF
		exit 1
	fi
	echo "== replacing the $PREV variant with the $MODE one"
	systemctl disable --now vep1400-net.service vep1400.service 2>/dev/null || true
	modprobe -r vep1400 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# files both modes need

echo "== installing common files"
install -d "$LIB_DIR" "$DOC_DIR" "$UNIT_DIR"
install -m 0755 "$HERE/scripts/vep1400-netup.sh" "$LIB_DIR/"
install -m 0755 "$HERE/scripts/vep1400-teardown.sh" "$LIB_DIR/"
install -m 0755 "$HERE/scripts/vep1400-report.sh" "$LIB_DIR/"
install -m 0755 "$HERE/scripts/vep1400-linkdiag.sh" "$LIB_DIR/"
install -m 0755 "$HERE/scripts/vep1400-userspace.py" "$TOOL"
install -m 0644 "$HERE/systemd/vep1400-net.service" "$UNIT_DIR/"
for f in README.md README.en.md LICENSE; do
	if [ -f "$HERE/$f" ]; then
		install -m 0644 "$HERE/$f" "$DOC_DIR/"
	fi
done

# ---------------------------------------------------------------------------
# mode specific parts

if [ "$MODE" = module ]; then
	echo "== kernel module mode"
	install -m 0644 "$HERE/systemd/vep1400.service" "$UNIT_DIR/"
	install -m 0644 "$HERE/modprobe/vep1400.conf" /etc/modprobe.d/

	if [ "$USE_DKMS" -eq 1 ] && command -v dkms >/dev/null 2>&1; then
		echo "== building through DKMS"
		rm -rf "$SRC_DIR"
		install -d "$SRC_DIR"
		cp -a "$HERE/Makefile" "$HERE/dkms.conf" "$HERE/src" "$SRC_DIR/"
		dkms add -m vep1400 -v "$VERSION" 2>/dev/null || true
		dkms build -m vep1400 -v "$VERSION" --force
		dkms install -m vep1400 -v "$VERSION" --force
	else
		echo "== building for the running kernel"
		make -C "$HERE" modules
		install -d "/lib/modules/$KVER/updates/dkms"
		install -m 0644 "$HERE/src/vep1400.ko" "/lib/modules/$KVER/updates/dkms/"
		depmod -a "$KVER"
	fi

	if [ "$USE_INITRAMFS" -eq 1 ] && [ -d /etc/initramfs-tools ]; then
		echo "== adding the module to the initramfs"
		install -m 0755 "$HERE/initramfs/hook-vep1400" /etc/initramfs-tools/hooks/vep1400
		install -m 0755 "$HERE/initramfs/local-top-vep1400" "$LIB_DIR/vep1400-initramfs"
		update-initramfs -u
	fi
else
	echo "== userspace mode"
	install -m 0644 "$HERE/systemd/vep1400-userspace.service" "$UNIT_DIR/vep1400.service"
	# No module: drop anything the module mode may have left behind.
	rm -f /etc/modprobe.d/vep1400.conf
	rm -f /etc/initramfs-tools/hooks/vep1400
	rm -f "$LIB_DIR/vep1400-initramfs"
fi

systemctl daemon-reload
systemctl enable vep1400.service vep1400-net.service

if [ "$START" -eq 1 ]; then
	echo "== (re)starting"
	systemctl restart vep1400.service
	systemctl restart vep1400-net.service || true
	sleep 1
fi

if [ "$MODE" = module ]; then
	WHAT="  mode     : kernel module (vep1400.ko), rebuilt by DKMS on kernel upgrades
  services : vep1400.service      loads the module before igb/ixgbe
             vep1400-net.service  creates GE1..GE6, names SFP1/SFP2
  state    : /sys/kernel/debug/vep1400/{info,ports,phy}
  params   : /etc/modprobe.d/vep1400.conf"
else
	WHAT="  mode     : userspace ($TOOL), no kernel module, no kernel taint
  services : vep1400.service      runs the tool at boot
             vep1400-net.service  creates GE1..GE6, names SFP1/SFP2
  state    : $TOOL info | phy | watch 60"
fi

cat <<EOF

Done.

$WHAT
  report   : $LIB_DIR/vep1400-report.sh
  portdiag : $LIB_DIR/vep1400-linkdiag.sh <1-6>

Configure addresses on GE1..GE6 (and SFP1/SFP2).  Never configure eno1/eno2,
they are the internal switch uplinks.

To switch implementation:  ./uninstall.sh && ./install.sh [--userspace]
Reboot once to verify that everything comes up on its own.
EOF
