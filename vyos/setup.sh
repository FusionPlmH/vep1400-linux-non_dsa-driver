#!/bin/bash
# Dell VEP1400 / VMware SD-WAN Edge 610 - install the userspace bring-up on
# VyOS.
#
#   sudo ./vyos/setup.sh            install + enable at boot + run now
#   sudo ./vyos/setup.sh --dry-run  only print what would be done
#
# Why userspace and not the kernel module: VyOS ships no compiler and no kernel
# headers, so vep1400.ko cannot be built on the box (its /lib/modules/*/build
# only contains a handful of UAPI headers). The switch, the front panel PHYs,
# the watchdog and the SFP cages can all be programmed from userspace through
# /dev/mem and /dev/i2c-0, which needs neither.

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO=$(dirname "$HERE")
DEST=/config/scripts
TOOL="$DEST/vep1400-userspace.py"
HOOK="$DEST/vyos-postconfig-bootup.script"
DRY=0

for arg in "$@"; do
	case "$arg" in
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

[ -f /opt/vyatta/bin/vyatta-op-cmd-wrapper ] ||
	[ -d /opt/vyatta ] || {
	echo "this does not look like VyOS (/opt/vyatta missing)" >&2
	exit 1
}

echo "== installing $TOOL"
echo "== installing $HOOK"
if [ "$DRY" -eq 1 ]; then
	echo "   (dry run, nothing written)"
	exit 0
fi

install -d "$DEST"
install -m 0755 "$REPO/scripts/vep1400-userspace.py" "$TOOL"
install -m 0755 "$HERE/vyos-postconfig-bootup.script" "$HOOK"

echo "== loading i2c modules"
modprobe i2c_ismt 2>/dev/null || true
modprobe i2c-dev 2>/dev/null || true

echo "== programming the switch"
python3 "$TOOL" init

cat <<'EOF'

Done. The boot hook repeats this on every boot (VyOS keeps /config across
image upgrades, /usr does not).

Front panel ports are vifs on the two uplinks:

  configure
  set interfaces ethernet eth0 vif 3 address dhcp     # front panel 3
  set interfaces ethernet eth1 vif 6 address dhcp     # front panel 6
  commit
  save

Never address eth0/eth1 themselves, they carry tagged traffic only.
State: python3 /config/scripts/vep1400-userspace.py info | phy
EOF
