#!/bin/bash
# Dell VEP1400 / VMware SD-WAN Edge 610 board support.
#
# The implementation is chosen automatically:
#
#   Debian / Ubuntu / Proxmox VE  ->  kernel module (default)
#   VyOS                          ->  userspace (it has no compiler and no
#                                     kernel headers, and /config is the only
#                                     place that survives an image upgrade)
#
#   sudo ./install.sh               pick the default for this system
#   sudo ./install.sh --userspace   force the userspace implementation
#   sudo ./install.sh --module      force the kernel module (refused on VyOS)
#
# Other options:
#   --no-start     install and enable, do not start now (reboot to use)
#   --no-dkms      module mode: build for the running kernel only
#   --no-deps      module mode: do not apt install missing build dependencies
#   --initramfs    module mode: also load the module from the initramfs
#   --force        replace a previously installed version of the other mode
#   --dry-run      VyOS: only print what would be done

set -euo pipefail

VERSION="2.0.0"
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SRC_DIR="/usr/src/vep1400-$VERSION"
LIB_DIR="/usr/lib/vep1400"
DOC_DIR="/usr/share/doc/vep1400"
UNIT_DIR="/etc/systemd/system"
TOOL="$LIB_DIR/vep1400-userspace.py"

MODE="module"
MODE_EXPLICIT=0
START=1
USE_DKMS=1
USE_INITRAMFS=0
AUTO_DEPS=1
FORCE=0
DRY=0
for arg in "$@"; do
	case "$arg" in
	--userspace) MODE="userspace"; MODE_EXPLICIT=1 ;;
	--module) MODE="module"; MODE_EXPLICIT=1 ;;
	--no-start) START=0 ;;
	--no-dkms) USE_DKMS=0 ;;
	--no-deps) AUTO_DEPS=0 ;;
	--initramfs) USE_INITRAMFS=1 ;;
	--force) FORCE=1 ;;
	--dry-run) DRY=1 ;;
	-h | --help)
		awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
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

detect_platform() {
	if [ -d /opt/vyatta ] || grep -qs '^ID=vyos' /etc/os-release; then
		echo vyos
	elif [ -e /etc/pve ]; then
		echo proxmox
	elif grep -qs '^ID=ubuntu' /etc/os-release; then
		echo ubuntu
	elif grep -qsE '^ID=debian|^ID_LIKE=.*debian' /etc/os-release; then
		echo debian
	else
		echo unknown
	fi
}

PLATFORM=$(detect_platform)

headers_package() {
	case "$PLATFORM" in
	proxmox) echo "proxmox-headers-$KVER" ;;
	*) echo "linux-headers-$KVER" ;;
	esac
}

apt_install() {
	DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# A fresh Debian/Ubuntu/PVE install usually lacks all three: the headers for
# the running kernel, make/gcc, and dkms. Installing the headers alone still
# leaves "make: command not found", so they are pulled in together.
ensure_module_deps() {
	local want=() pkg

	[ -d "/lib/modules/$KVER/build" ] || want+=("$(headers_package)")
	command -v make >/dev/null 2>&1 || want+=(make)
	command -v gcc >/dev/null 2>&1 || want+=(gcc)
	if [ "$USE_DKMS" -eq 1 ] && ! command -v dkms >/dev/null 2>&1; then
		want+=(dkms)
	fi
	[ "${#want[@]}" -eq 0 ] && return 0

	if ! command -v apt-get >/dev/null 2>&1; then
		echo "== missing build dependencies: ${want[*]} (no apt-get here)" >&2
		return 1
	fi

	echo "== installing build dependencies: ${want[*]}"
	apt-get update || true
	for pkg in "${want[@]}"; do
		apt_install "$pkg" || true
	done
	# PVE 8.0/8.1 shipped the headers as pve-headers-*, 8.2+ renamed them.
	if [ ! -d "/lib/modules/$KVER/build" ] && [ "$PLATFORM" = proxmox ]; then
		apt_install "pve-headers-$KVER" || true
	fi
}

if [ "$PLATFORM" = vyos ]; then
	if [ "$MODE_EXPLICIT" = 1 ] && [ "$MODE" = module ]; then
		cat >&2 <<'EOF'
ERROR: VyOS cannot use the kernel module: the image ships no compiler and no
       kernel headers, and it has no DKMS to rebuild after kernel upgrades.
       Drop --module (VyOS always gets the userspace implementation).
EOF
		exit 1
	fi

	echo "detected VyOS: userspace implementation only"
	for opt in --no-start --no-dkms --no-deps --initramfs; do
		case " $* " in
		*" $opt "*) echo "   note: $opt does not apply on VyOS" >&2 ;;
		esac
	done
	if [ -f "$UNIT_DIR/vep1400.service" ] &&
		! grep -q 'userspace' "$UNIT_DIR/vep1400.service" 2>/dev/null; then
		echo "   note: a generic vep1400.service is installed; ./uninstall.sh" >&2
		echo "         removes it if you want a clean VyOS-only setup" >&2
	fi

	VYOS_ARGS=()
	[ "$DRY" -eq 1 ] && VYOS_ARGS+=(--dry-run)
	exec bash "$HERE/vyos/setup.sh" "${VYOS_ARGS[@]}"
fi

echo "detected platform: $PLATFORM, implementation: $MODE"

if [ "$DRY" -eq 1 ]; then
	echo "ERROR: --dry-run is only implemented for VyOS" >&2
	exit 1
fi

if [ "$MODE" = module ]; then
	KVER=$(uname -r)
	if [ "$AUTO_DEPS" -eq 1 ]; then
		ensure_module_deps || true
	fi
	[ -d "/lib/modules/$KVER/build" ] || {
		echo "ERROR: /lib/modules/$KVER/build is missing." >&2
		echo "       apt install $(headers_package)" >&2
		echo "       or install the userspace variant:  $0 --userspace" >&2
		exit 1
	}
	for tool in make gcc; do
		command -v "$tool" >/dev/null 2>&1 || {
			echo "ERROR: $tool is missing: apt install build-essential" >&2
			echo "       or install the userspace variant:  $0 --userspace" >&2
			exit 1
		}
	done
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
