#!/bin/bash
# Dell VEP1400 / VMware Edge 610 - read-only status report.
#
#   vep1400-report.sh          human readable summary
#
# Useful when reporting a problem: it never writes to any register.

set -u

MODULE=vep1400
DEBUGFS=/sys/kernel/debug/vep1400

echo "== board =="
for f in sys_vendor product_name board_name bios_version; do
	[ -r "/sys/class/dmi/id/$f" ] &&
		printf '%-14s %s\n' "$f:" "$(cat "/sys/class/dmi/id/$f")"
done
echo

echo "== kernel =="
uname -srm
echo

echo "== PCI =="
lspci -nn 2>/dev/null | grep -E '15c3|19dd|19ac|19d[0-3]' || echo "none"
echo

echo "== modules =="
lsmod | grep -E '^(vep1400|ixgbe|i2c_ismt)' || echo "none loaded"
echo

echo "== module parameters =="
for p in /sys/module/$MODULE/parameters/*; do
	[ -r "$p" ] && printf '   %-14s %s\n' "${p##*/}" "$(cat "$p")"
done 2>/dev/null
echo

echo "== netdevs =="
ip -br link
echo

echo "== module state =="
[ -r "$DEBUGFS/info" ] && cat "$DEBUGFS/info"
echo

echo "== front panel ports =="
if [ -r "$DEBUGFS/ports" ]; then
	cat "$DEBUGFS/ports"
else
	echo "debugfs $DEBUGFS missing (module loaded? root?)"
fi
echo

echo "== PHY registers =="
[ -r "$DEBUGFS/phy" ] && cat "$DEBUGFS/phy"
echo

echo "== uplinks =="
for dev in eno1 eno2 SFP1 SFP2 eno3 eno4; do
	[ -e "/sys/class/net/$dev" ] || continue
	echo "-- $dev ($(cat "/sys/class/net/$dev/operstate"))"
	ethtool "$dev" 2>/dev/null | grep -E 'Speed|Duplex|Link detected'
done
echo

echo "== services =="
systemctl is-active vep1400.service vep1400-net.service 2>/dev/null |
	paste -d' ' - -
echo

echo "== kernel log =="
dmesg 2>/dev/null | grep -E "$MODULE|ixgbe" | tail -30
