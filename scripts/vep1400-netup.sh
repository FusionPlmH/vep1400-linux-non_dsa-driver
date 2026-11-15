#!/bin/bash
# Dell VEP1400 / VMware SD-WAN Edge 610 - create GE1..GE6 and name the SFP
# cages.
#
#   GE1..GE3 -> eno1 (0000:03:00.0) -> switch port 10, VLAN 1..3
#   GE4..GE6 -> eno2 (0000:03:00.1) -> switch port  9, VLAN 4..6
#   SFP1     -> 0000:05:00.1
#   SFP2     -> 0000:05:00.0
#
# This script works with either implementation:
#
#   kernel module - vep1400.ko is loaded first (softdep ixgbe pre: vep1400),
#                   so nothing has to be unloaded here.  Only if something
#                   probed ixgbe before us (a built-in ixgbe, a custom
#                   initramfs) the driver is reloaded once.
#   userspace     - vep1400.service already ran vep1400-userspace.py init, so
#                   there is no module to touch and no debugfs to consult.
#
# The mode is detected, not configured.

set -u

MODULE="vep1400"
TAG="vep1400-net"
DEBUGFS=/sys/kernel/debug/vep1400
DEBUGFS_PORTS="$DEBUGFS/ports"

log() { echo "$TAG: $*"; }
die() { echo "$TAG: ERROR: $*" >&2; exit 1; }

module_present() {
	command -v modinfo >/dev/null 2>&1 && modinfo -n "$MODULE" >/dev/null 2>&1
}

is_vep1400() {
	local f

	for f in /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name \
		 /sys/class/dmi/id/sys_vendor; do
		[ -r "$f" ] || continue
		case "$(cat "$f" 2>/dev/null)" in
		*EDGE610*|*Edge610*|*edge610*|*VEP1400*|*vep1400*) return 0 ;;
		esac
	done
	[ -e /sys/bus/pci/devices/0000:03:00.0 ] &&
		[ -e /sys/bus/pci/devices/0000:03:00.1 ]
}

netdev_at() {
	local dir="/sys/bus/pci/devices/$1/net"

	[ -d "$dir" ] || return 1
	ls "$dir" 2>/dev/null | head -1
}

wait_netdev() {
	local pci=$1 i dev

	for ((i = 0; i < 200; i++)); do
		dev=$(netdev_at "$pci" || true)
		if [ -n "${dev:-}" ]; then
			echo "$dev"
			return 0
		fi
		sleep 0.1
	done
	return 1
}

switch_port_up() {
	[ -r "$DEBUGFS_PORTS" ] || return 1
	awk -v p="$1" '$1 == p && $8 == "up" { found = 1 } END { exit !found }' \
		"$DEBUGFS_PORTS"
}

cpu_links_up() {
	[ -r "$DEBUGFS_PORTS" ] || return 0
	switch_port_up 9 && switch_port_up 10
}

strap_busy() {
	[ -r "$DEBUGFS/info" ] || return 1
	awk '$1 == "x553_strap" && $2 == "busy" { found = 1 } END { exit !found }' \
		"$DEBUGFS/info"
}

ensure_ixgbe() {
	local dev

	for dev in 0000:03:00.0 0000:03:00.1; do
		[ -d "/sys/bus/pci/devices/$dev/net" ] && continue
		log "loading ixgbe for the switch uplinks"
		modprobe ixgbe || return 1
		return 0
	done
	return 0
}

reload_ixgbe() {
	local dev n

	for n in 1 2 3 4 5 6; do
		ip link del "GE$n" 2>/dev/null || true
	done
	for dev in $(netdev_at 0000:03:00.0) $(netdev_at 0000:03:00.1); do
		ip link set dev "$dev" down 2>/dev/null || true
	done
	modprobe -r ixgbe || return 1
	modprobe -r "$MODULE" 2>/dev/null || true
	modprobe "$MODULE" || return 1
	modprobe ixgbe || return 1
	return 0
}

rename_if() {
	local dev=$1 name=$2

	[ -n "$dev" ] || return 0
	[ "$dev" = "$name" ] && return 0
	if ip link show "$name" >/dev/null 2>&1; then
		log "$name already exists, leaving $dev alone"
		return 0
	fi
	ip link set dev "$dev" down 2>/dev/null || true
	if ip link set dev "$dev" name "$name" 2>/dev/null; then
		log "renamed $dev -> $name"
	else
		log "WARNING: could not rename $dev -> $name"
	fi
}

# Unique MAC per VLAN device: base MAC + 0x0a + index (last octet only)
vlan_mac() {
	local base=$1 idx=$2

	printf '%s:%02x' "${base%:*}" $(( (16#${base##*:} + 10 + idx) & 0xff ))
}

ensure_vlan() {
	local parent=$1 name=$2 vid=$3 mac=$4 alt

	if ip link show "$name" >/dev/null 2>&1; then
		ip link set dev "$name" address "$mac" 2>/dev/null || true
		ip link set dev "$name" up
		return 0
	fi

	# A VLAN with the same parent and id may already exist under another
	# name - a VyOS "vif 3" creates eth0.3, for instance. The kernel refuses
	# a second device for the same (parent, id), so reuse it instead of
	# fighting over it.
	alt="$parent.$vid"
	if ip link show "$alt" >/dev/null 2>&1; then
		log "$name already exists as $alt, using it as is"
		ip link set dev "$alt" up 2>/dev/null || true
		return 0
	fi

	ip link add link "$parent" name "$name" type vlan id "$vid" || return 1
	ip link set dev "$name" address "$mac" 2>/dev/null || true
	ip link set dev "$name" up
	# Do not answer ARP for addresses that live on another interface
	echo 1 > "/proc/sys/net/ipv4/conf/$name/arp_ignore" 2>/dev/null || true
	echo 2 > "/proc/sys/net/ipv4/conf/$name/arp_announce" 2>/dev/null || true
	return 0
}

is_vep1400 || { log "not a VEP1400/Edge 610, nothing to do"; exit 0; }

[ -d /sys/kernel/debug ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null

if module_present; then
	MODE=module
	modprobe "$MODULE" || die "modprobe $MODULE failed (see dmesg)"
else
	MODE=userspace
	log "no vep1400 module installed, using the userspace bring-up"
fi

ensure_ixgbe || die "could not load ixgbe"

CONDUIT_A=$(wait_netdev 0000:03:00.0) || die "no netdev for 0000:03:00.0 (is ixgbe loaded?)"
CONDUIT_B=$(wait_netdev 0000:03:00.1) || die "no netdev for 0000:03:00.1 (is ixgbe loaded?)"

if [ "$MODE" = module ] && strap_busy; then
	log "ixgbe probed before the X553 strap was applied, reloading it once"
	reload_ixgbe || die "could not reload ixgbe (see dmesg)"
	CONDUIT_A=$(wait_netdev 0000:03:00.0) || die "0000:03:00.0 netdev missing"
	CONDUIT_B=$(wait_netdev 0000:03:00.1) || die "0000:03:00.1 netdev missing"
fi

if [ -r "$DEBUGFS_PORTS" ]; then
	if cpu_links_up; then
		log "both X553 CPU links are up"
	else
		log "WARNING: switch CPU ports 9/10 are down (check x553_speed)"
	fi
else
	log "CPU link state not exposed (userspace mode):" \
	    "$(cat "/sys/class/net/$CONDUIT_A/operstate" 2>/dev/null)" \
	    "$(cat "/sys/class/net/$CONDUIT_B/operstate" 2>/dev/null)"
fi
log "uplinks: $CONDUIT_A (switch port 10), $CONDUIT_B (switch port 9)"

rename_if "$(netdev_at 0000:05:00.1 || true)" SFP1
rename_if "$(netdev_at 0000:05:00.0 || true)" SFP2

ip link set dev "$CONDUIT_A" up
ip link set dev "$CONDUIT_B" up

BASE_MAC=$(cat "/sys/class/net/$CONDUIT_A/address" 2>/dev/null || echo "02:00:00:00:00:00")

for i in 0 1 2; do
	ensure_vlan "$CONDUIT_A" "GE$((i + 1))" "$((i + 1))" \
		"$(vlan_mac "$BASE_MAC" "$i")" || die "failed to create GE$((i + 1))"
done
for i in 0 1 2; do
	ensure_vlan "$CONDUIT_B" "GE$((i + 4))" "$((i + 4))" \
		"$(vlan_mac "$BASE_MAC" "$((i + 3))")" || die "failed to create GE$((i + 4))"
done

log "GE1-GE6 ready, SFP1/SFP2 named (configure GE* only, never eno1/eno2)"
exit 0
