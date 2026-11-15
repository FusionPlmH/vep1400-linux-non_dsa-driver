#!/bin/bash
# Dell VEP1400 / VMware Edge 610 - read-only status report.
#
#   vep1400-report.sh          human readable summary
#
# Works with both implementations (kernel module and userspace) and never
# writes to a register.  Useful when reporting a problem.

set -u

MODULE=vep1400
DEBUGFS=/sys/kernel/debug/vep1400
TOOL=/usr/lib/vep1400/vep1400-userspace.py

echo "== board =="
for f in sys_vendor product_name board_name bios_version; do
	[ -r "/sys/class/dmi/id/$f" ] &&
		printf '%-14s %s\n' "$f:" "$(cat "/sys/class/dmi/id/$f")"
done
echo

echo "== kernel =="
uname -srm
echo

echo "== implementation =="
if [ -d "/sys/module/$MODULE" ]; then
	echo "kernel module, loaded"
elif [ -f "$TOOL" ]; then
	echo "userspace ($TOOL)"
else
	echo "neither installed"
fi
echo

echo "== PCI =="
lspci -nn 2>/dev/null | grep -E '15c3|19dd|19ac|19d[0-3]' || echo "none"
echo

echo "== modules =="
lsmod | grep -E '^(vep1400|ixgbe|i2c_ismt|i2c_dev)' || echo "none loaded"
echo

if [ -d "/sys/module/$MODULE/parameters" ]; then
	echo "== module parameters =="
	for p in /sys/module/$MODULE/parameters/*; do
		[ -r "$p" ] && printf '   %-14s %s\n' "${p##*/}" "$(cat "$p")"
	done
	echo
fi

echo "== netdevs =="
ip -br link
echo

if [ -r "$DEBUGFS/info" ]; then
	echo "== module state =="
	cat "$DEBUGFS/info"
	echo

	echo "== front panel ports =="
	cat "$DEBUGFS/ports"
	echo

	echo "== PHY registers =="
	[ -r "$DEBUGFS/phy" ] && cat "$DEBUGFS/phy"
	echo
elif [ -x "$TOOL" ] && command -v python3 >/dev/null 2>&1; then
	echo "== switch state (userspace) =="
	python3 "$TOOL" info 2>&1
	echo

	echo "== PHY registers (userspace) =="
	python3 "$TOOL" phy 2>&1
	echo
else
	echo "== switch state =="
	echo "no way to read the switch: neither $DEBUGFS nor $TOOL is available"
	echo
fi

echo "== uplinks =="
for dev in eno1 eno2 SFP1 SFP2 eno3 eno4 eth0 eth1 eth2 eth3; do
	[ -e "/sys/class/net/$dev" ] || continue
	speed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null)
	echo "-- $dev ($(cat "/sys/class/net/$dev/operstate"), ${speed:--} Mb/s)"
	if command -v ethtool >/dev/null 2>&1; then
		ethtool "$dev" 2>/dev/null | grep -E 'Duplex|Link detected'
	fi
done
echo

echo "== services =="
systemctl is-active vep1400.service vep1400-net.service 2>/dev/null |
	paste -d' ' - -
echo

echo "== kernel log =="
dmesg 2>/dev/null | grep -E "$MODULE|ixgbe" | tail -30
