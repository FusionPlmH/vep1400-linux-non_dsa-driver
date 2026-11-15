#!/bin/bash
# Remove the Dell VEP1400 / VMware SD-WAN Edge 610 board support.
#
# Removes either implementation (kernel module or userspace) - they share the
# same unit names, so there is nothing to choose here.
#
# On VyOS the files live in /config, use a different mechanism; the hook there
# is /config/scripts/vyos-postconfig-bootup.script and removing it plus
# /config/scripts/vep1400-userspace.py is enough.

set -u

VERSION="2.0.0"
LIB_DIR="/usr/lib/vep1400"
DOC_DIR="/usr/share/doc/vep1400"
KVER=$(uname -r)

[ "$(id -u)" -eq 0 ] || {
	echo "run as root" >&2
	exit 1
}

systemctl disable --now vep1400-net.service vep1400.service 2>/dev/null || true

for n in 1 2 3 4 5 6; do
	ip link del "GE$n" 2>/dev/null || true
done

# Give the SFP cages their kernel names back
for pair in "SFP1:eno4" "SFP2:eno3"; do
	name=${pair%%:*}
	orig=${pair##*:}
	if ip link show "$name" >/dev/null 2>&1 &&
	   ! ip link show "$orig" >/dev/null 2>&1; then
		ip link set dev "$name" down 2>/dev/null || true
		ip link set dev "$name" name "$orig" 2>/dev/null || true
	fi
done

modprobe -r vep1400 2>/dev/null || true

if command -v dkms >/dev/null 2>&1; then
	dkms remove -m vep1400 -v "$VERSION" --all 2>/dev/null || true
fi

rm -rf /usr/src/vep1400-"$VERSION" "$LIB_DIR" "$DOC_DIR"
rm -f /etc/systemd/system/vep1400.service \
	/etc/systemd/system/vep1400-net.service \
	/etc/modprobe.d/vep1400.conf \
	"/lib/modules/$KVER/updates/dkms/vep1400.ko" \
	"/lib/modules/$KVER/extra/vep1400/vep1400_switch.ko" \
	"/lib/modules/$KVER/extra/vep1400/vep1400_i2c.ko"

# Rebuild the initramfs without the early-load hook, otherwise the next boot
# still loads vep1400 from the (now stale) initramfs.
if [ -f /etc/initramfs-tools/hooks/vep1400 ]; then
	rm -f /etc/initramfs-tools/hooks/vep1400
	command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u
fi

depmod -a "$KVER" 2>/dev/null || true
systemctl daemon-reload

echo "removed. ixgbe is untouched; reboot to return to the stock setup."
