#!/bin/bash
# Remove the Dell VEP1400 / VMware SD-WAN Edge 610 board support.
#
# Removes either implementation (kernel module or userspace) - they share the
# same unit names - and the VyOS-specific files in /config.

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

# The unit's ExecStop already ran the teardown; run it once more in case the
# unit was missing or had been disabled earlier.
[ -x "$LIB_DIR/vep1400-teardown.sh" ] && "$LIB_DIR/vep1400-teardown.sh" 2>/dev/null

modprobe -r vep1400 2>/dev/null || true

if command -v dkms >/dev/null 2>&1; then
	dkms remove -m vep1400 -v "$VERSION" --all 2>/dev/null || true
fi

rm -rf /usr/src/vep1400-"$VERSION" "$LIB_DIR" "$DOC_DIR"
rm -f /etc/systemd/system/vep1400.service \
	/etc/systemd/system/vep1400-net.service \
	/etc/modprobe.d/vep1400.conf \
	"/lib/modules/$KVER/updates/dkms/vep1400.ko"

# Rebuild the initramfs without the early-load hook, otherwise the next boot
# still loads vep1400 from the (now stale) initramfs.
if [ -f /etc/initramfs-tools/hooks/vep1400 ]; then
	rm -f /etc/initramfs-tools/hooks/vep1400
	command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u
fi

depmod -a "$KVER" 2>/dev/null || true
systemctl daemon-reload

# VyOS keeps the tool and its boot hook in /config, which outlives /usr.
if [ -f /config/scripts/vep1400-userspace.py ]; then
	rm -f /config/scripts/vep1400-userspace.py
	echo "removed /config/scripts/vep1400-userspace.py"
fi
if [ -f /config/scripts/vyos-postconfig-bootup.script ] &&
	grep -q 'vep1400-userspace.py' /config/scripts/vyos-postconfig-bootup.script; then
	rm -f /config/scripts/vyos-postconfig-bootup.script
	echo "removed /config/scripts/vyos-postconfig-bootup.script"
fi

echo "removed. ixgbe is untouched; reboot to return to the stock setup."
