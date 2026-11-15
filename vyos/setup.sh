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
		sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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

Done.

The board is now set up, and /config/scripts/vyos-postconfig-bootup.script
repeats that on every boot (VyOS keeps /config across image upgrades, the rest
of the filesystem does not).

Configure the front panel ports with VLAN interfaces on the two uplinks:

  configure
  set interfaces ethernet eth0 vif 1 address 192.168.10.1/24   # front panel 1
  set interfaces ethernet eth0 vif 2 address 192.168.20.1/24   # front panel 2
  set interfaces ethernet eth0 vif 3 address dhcp              # front panel 3
  set interfaces ethernet eth1 vif 4 address 192.168.40.1/24   # front panel 4
  set interfaces ethernet eth1 vif 5 address 192.168.50.1/24   # front panel 5
  set interfaces ethernet eth1 vif 6 address dhcp              # front panel 6
  commit
  save

Do not put an address on eth0/eth1 themselves: they carry tagged traffic only.
Check the state of the ports any time with

  python3 /config/scripts/vep1400-userspace.py info
  python3 /config/scripts/vep1400-userspace.py phy

If you upgrade the VyOS image, /config survives but /usr does not: rerun this
script afterwards only to refresh the copy of the tool, the hook is already
persistent.
EOF
