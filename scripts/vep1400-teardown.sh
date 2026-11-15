#!/bin/bash
# Remove the GE1..GE6 VLAN devices and restore the SFP port names.

set -u

for n in 1 2 3 4 5 6; do
	ip link del "GE$n" 2>/dev/null || true
done

for pair in "SFP1:eno4" "SFP2:eno3"; do
	name=${pair%%:*}
	orig=${pair##*:}
	if ip link show "$name" >/dev/null 2>&1 &&
	   ! ip link show "$orig" >/dev/null 2>&1; then
		ip link set dev "$name" down 2>/dev/null || true
		ip link set dev "$name" name "$orig" 2>/dev/null || true
	fi
done
exit 0
