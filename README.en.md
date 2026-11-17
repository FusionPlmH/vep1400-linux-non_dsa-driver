**English** &nbsp;·&nbsp; [简体中文](README.md)

# Dell VEP1400 / VMware Edge 610 — driver for stock Linux

Runs the **Dell VEP1400** (= **VMware SD-WAN Edge 610**, non-X, Intel Atom C3308)
with all six front panel RJ45 ports and both SFP cages on a **stock Debian /
Ubuntu / Proxmox VE / VyOS** — no custom kernel, no device tree, no DSA.

**Quick start** · [Systems](#systems-and-implementations) · [Port map](#port-map) · [Using the ports](#using-the-ports) · [Verify](#verify) · [Troubleshooting](#troubleshooting) · [Hardware](#hardware) · [Layout](#layout)

```text
   GE1..GE3 ─┐
             ├─ port 10 ─ 802.1Q ─ X553 03:00.0 ─ eno1
   GE4..GE6 ─┤   88E6190
             └─ port  9 ─ 802.1Q ─ X553 03:00.1 ─ eno2

   SFP1 ─ X553 05:00.1          SFP2 ─ X553 05:00.0
```

The switch is a Marvell 88E6190, and the usual way to expose it is DSA, which
would give the kernel `GE1`…`GE6` — but Debian, Ubuntu, PVE and VyOS all ship
`# CONFIG_NET_DSA is not set` (VyOS disables `CONFIG_NET_SWITCHDEV` too), and the
SMI bus is not wired to any MDIO controller, so it cannot be described in ACPI or
device tree either. Rebuilding every target kernel for one board is not an
option, so this takes the vendor's DiagOS route instead: the switch is configured
as **one 802.1Q VLAN per front panel port** and Linux simply sees six ordinary
Ethernet interfaces.

The configuration is bit-banged over the Denverton P2SB pads that Dell's firmware
hides. The six PHYs are powered up and set up once at load time and then left
entirely to autonegotiation — plug a cable and it behaves like any other NIC. It
also disarms the PIC watchdog and enables SFP TX. The uplinks negotiate
`1000baseKX/Full` (switch ↔ X553 over 1000BASE-X); **2.5G never links** on this
board.

Tested on real hardware: all six ports negotiate 1000 Mb/s (Debian 13 and VyOS
1.3.4).

## Quick start

### 1. Get a management path first

Installing needs kernel headers and build packages (`install.sh` apt-installs
what is missing), and loading the driver briefly disturbs
the GE ports. This board has a single management plane and is passively cooled,
so **Wi-Fi is the easiest choice**; never make a GE port your only management
link during the install.

**VyOS** — do not skip `name-server`, VyOS ships without DNS, so
`ping deb.debian.org` fails while `ping 1.1.1.1` works:

```text
configure
set system name-server 1.1.1.1
set interfaces wireless wlan0 type station
set interfaces wireless wlan0 physical-device phy0
set interfaces wireless wlan0 ssid "<SSID>"
set interfaces wireless wlan0 security wpa mode wpa2
set interfaces wireless wlan0 security wpa passphrase "<PSK>"
set interfaces wireless wlan0 address dhcp
commit
save
```

**Debian / Proxmox VE** — ifupdown + wpasupplicant, PVE uses the same file:

```sh
apt install -y wpasupplicant
cat >> /etc/network/interfaces <<'EOF'

auto wlp2s0
iface wlp2s0 inet dhcp
	wpa-ssid <SSID>
	wpa-psk  <PSK>
EOF
ifup wlp2s0
```

**Ubuntu Server** — netplan, write `/etc/netplan/50-wifi.yaml` then
`sudo netplan apply`:

```yaml
network:
  version: 2
  wifis:
    wlp2s0:
      access-points:
        "<SSID>":
          password: "<PSK>"
      dhcp4: true
```

> Replace `wlp2s0` with your actual wireless interface name — `ip -br link`
> lists them.

### 2. Check you are really online

Two commands, identical on Debian / PVE / VyOS, and you do not need to know the
interface name:

```sh
ip route get 1.1.1.1        # which interface the default route leaves through
ping -c1 deb.debian.org     # resolves and replies -> link, route and DNS are fine
```

### 3. Install

```sh
wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh | sudo bash
wget -qO- https://neodev.team/get.sh | sudo bash                     # mirror, if GitHub is unreachable
```

To pass an option, append `-s -- <option>` after `bash` (see the table below).
Or clone it and use the script directly:

```sh
git clone https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver.git
cd vep1400-linux-non_dsa-driver
sudo ./install.sh
```

| Option | Effect |
|---|---|
| *(none)* | auto-select: Debian/Ubuntu/PVE → kernel module + DKMS, VyOS → userspace |
| `--userspace` | force the userspace implementation: nothing compiled, no kernel taint |
| `--module` | force the kernel module (refused on VyOS) |
| `--no-deps` | do not apt install the build dependencies: kernel headers, `make`/`gcc`, `dkms` (offline use) |
| `--initramfs` | also load the module from the initramfs (encrypted root, slow fsck) |
| `--no-dkms` | build for the running kernel only |
| `--no-start` | install and enable, do not start now |
| `--force` | replace the other implementation in place |

Uninstall: `sudo ./uninstall.sh` — removes the module, the userspace files under
`/usr`, and the VyOS files under `/config`.

## Systems and implementations

| System | Default | Also needs | Status |
|---|---|---|---|
| Debian 13 | kernel module | `linux-headers-$(uname -r)` + `dkms` | ✅ tested (13.7 / kernel 6.12) |
| Debian 12 | kernel module | same | not tested yet (kernel 6.1) |
| Ubuntu 22.04 / 24.04 | kernel module | same | not tested yet (kernel 5.15 / 6.8) |
| Proxmox VE 8 / 9 | kernel module | `proxmox-headers-$(uname -r)` (`pve-headers-` on 8.0/8.1) + `dkms` | not tested yet |
| VyOS 1.3.4 | userspace | `python3` + readable `/dev/mem` | ✅ tested (1.3.4 / kernel 5.4.261) |
| other systemd distributions | userspace | same | untested |

`install.sh` follows the table above and, in module mode, installs whatever is
missing with `apt-get` first (`linux-headers-$(uname -r)` /
`proxmox-headers-$(uname -r)`, `make`, `gcc`, `dkms`); `--no-deps` turns that
off. Any system can still force the userspace implementation with
`--userspace`, but it has to map the hidden P2SB window through `/dev/mem`,
which kernels built with `CONFIG_IO_STRICT_DEVMEM` refuse once ACPI marks the
`INTC3000` range exclusive (the Debian 13 / PVE kernel does). Boot with
`iomem=relaxed` to allow it, e.g. on Debian / PVE:

```sh
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 iomem=relaxed"/' /etc/default/grub
sudo update-grub && sudo reboot
```

(`iomem=relaxed` relaxes the kernel's strict `/dev/mem` checks; only add it
when you actually want the userspace implementation.)

`--userspace` probes this **before** touching an existing install and exits
when the mapping is refused. Both drive the same register sequences and
reach the same speed, but use **one per machine** — `install.sh` refuses to mix
them:

| | kernel module `vep1400.ko` | userspace `vep1400-userspace.py` |
|---|---|---|
| Shape | a DKMS-built kernel module | a Python script that writes the registers once at boot |
| Kernel upgrades | DKMS rebuilds it | nothing to do |
| X553 speed strap | programmable | not programmable (not needed on this board) |
| Kernel taint | yes | no |

> Hardware support is limited to the **Dell VEP1400 / VMware SD-WAN Edge 610
> non-X (Atom C3308)**. The Edge 610X / VEP1400-X uses a C3558 and a different
> switch configuration, which this version does not handle.

## Port map

Front panel ports 1–6 are six ordinary interfaces, `GE1`…`GE6`, on Debian /
Ubuntu / PVE. VyOS rejects those names, so it uses vifs on the two uplinks. The
SFP cages keep whatever name the kernel gave them on both.

| Front panel | Switch port | VLAN | Debian / Ubuntu / PVE | VyOS |
|---|---|---|---|---|
| 1 | 1 | 1 | `GE1` | `eth0 vif 1` |
| 2 | 2 | 2 | `GE2` | `eth0 vif 2` |
| 3 | 3 | 3 | `GE3` | `eth0 vif 3` |
| 4 | 4 | 4 | `GE4` | `eth1 vif 4` |
| 5 | 5 | 5 | `GE5` | `eth1 vif 5` |
| 6 | 6 | 6 | `GE6` | `eth1 vif 6` |
| SFP1 | — | untagged | `SFP1` | 05:00.1 (kernel name) |
| SFP2 | — | untagged | `SFP2` | 05:00.0 (kernel name) |

**Never** address the uplinks themselves: `eno1` / `eno2` on Debian / Ubuntu /
PVE (03:00.0 / 03:00.1), `eth0` / `eth1` on VyOS. `GE*` inherit their uplink's
MAC plus a per-port offset (`+0x0a`…`+0x0f`). On VyOS the SFP cages have no vif
and keep a kernel name that **changes between boots** (`eth2`/`eth3` and
`eno3`/`eno4` were both seen on this unit) — go by the PCI address above,
`ip -br link` or `/sys/class/net/*/device` tells you which is which.

## Using the ports

**Debian / Proxmox VE** (ifupdown) — `GE*` behave like any other NIC:

```sh
# /etc/network/interfaces
auto GE1
iface GE1 inet dhcp
```

**Ubuntu Server** (netplan):

```yaml
# /etc/netplan/60-ge.yaml
network:
  version: 2
  ethernets:
    GE1:
      dhcp4: true
```

**VyOS** — it rejects interface names like `GE1` (`Invalid Ethernet interface
name`), so use native vifs on the two uplinks; `vif N` is front panel port N:

```text
configure
set interfaces ethernet eth0 vif 3 address dhcp     # front panel 3
set interfaces ethernet eth1 vif 6 address dhcp     # front panel 6
commit
save
```

Three rules that always apply:

- **Never** put an address on the uplinks themselves (see the note above)
- **Never** bridge two ports — they already share a broadcast domain, that loops
- Two ports on one subnet is fine; `GE*` get `arp_ignore=1` / `arp_announce=2`
  automatically, VyOS vifs need them set by hand

## Verify

**Debian / Ubuntu / PVE**, both implementations install these scripts:

```sh
sudo /usr/lib/vep1400/vep1400-report.sh        # one-page summary
sudo /usr/lib/vep1400/vep1400-linkdiag.sh 3    # decode one port's autonegotiation
```

**VyOS** only gets the tool itself (only `/config` survives an image upgrade), so
call it directly:

```sh
python3 /config/scripts/vep1400-userspace.py info      # switch port table
python3 /config/scripts/vep1400-userspace.py diag 3    # decode one port
python3 /config/scripts/vep1400-userspace.py watch 60  # follow link changes
```

A healthy boot in module mode looks like this (userspace:
`journalctl -t vep1400`):

```text
vep1400: Marvell 88E6190 rev 1
vep1400: GE1 -> VLAN 1 via CPU port 10
vep1400: CPU port 10 link up (1G)
vep1400: CPU port 9 link up (1G)
vep1400: front panel PHYs powered up, autonegotiation running
vep1400: switch ready
vep1400: GE3 link up (1G)
```

## Troubleshooting

Start with `sudo /usr/lib/vep1400/vep1400-report.sh` (on VyOS
`python3 /config/scripts/vep1400-userspace.py info`) — it points at the problem
in most cases.

| Symptom | Fix |
|---|---|
| no `GE1`…`GE6` | `journalctl -u vep1400-net`; in module mode the script reloads `ixgbe` once if it probed first |
| reboots every 4–5 minutes, or dmesg says `no iSMT SMBus adapter` | same root cause: i2c is not up. `modprobe i2c_ismt`, and check `watchdog=1` plus early enough service start |
| a port only reaches 100M | `vep1400-linkdiag.sh <n>`: does the peer advertise 1000BASE-T? usually cable or peer port |
| `unexpected switch id` | SMI out of sync. Module mode: check `dmesg \| grep P2SB`, pass `p2sb_bar_addr=`; userspace mode: confirm `INTC3000` is in `/proc/iomem` |
| broken after a kernel upgrade | only module mode: `dkms status`, `journalctl -u dkms` |
| `--userspace` refused with P2SB / mmap EPERM | the kernel's `CONFIG_IO_STRICT_DEVMEM` will not let `/dev/mem` map the ACPI-exclusive P2SB window; boot with `iomem=relaxed`, or use the default module mode |

## Hardware

| | |
|---|---|
| System / board | Dell EMC `EDGE610` / `EDGE610-CPU`, BIOS `3.43.0.9-8` |
| CPU | Intel Atom **C3308** (Denverton, 2C/2T, 1.6 GHz, 4 MB L2, with QAT) |
| Memory | 4 GB DDR4-2400 ECC, **soldered**, not upgradeable |
| Storage | 16 GB eMMC (onboard) + **mSATA slot** + SD slot |
| LTE | **module slot** (optional; the Quectel in the reference unit was fitted by its owner, USB + `cdc_mbim` → `wwan0`) |
| Switch | Marvell 88E6190 rev 1 |
| NICs | 4× Intel X553 Backplane `8086:15c3` |
| Wi-Fi | QCA986x (`ath10k_pci`) on the reference unit — ideal as the management path |
| Front panel | 6× 10/100/1000BASE-T RJ45, 2× SFP |
| Console | `ttyS0`, 115200 8N1 |
| Cooling | passive, **no fan**, and no fan controller on the SMBus |
| Watchdog | PIC on SMBus `0x22`/`0x24`, resets the board 4–5 minutes after power-on unless disarmed |

<details>
<summary><b>What the PHY init does</b></summary>

After reset the front panel PHYs are **powered down** (`BMCR` reads back `0x1940`),
so the driver has to power them up explicitly or there is never a link. At load
time it writes, once per PHY:

- the DiagOS init sequence (page `0xf8`, reg `0x14`)
- `1000BASE-T control (0x09) = 0x0200`: advertise 1000BASE-T full duplex and let
  autonegotiation pick master/slave. The board default is `0x0e00`, where bit 11
  only expresses a *preference* for master and does not prevent negotiation
- `BMCR = 0x1140 | AN_RESTART`: power up and start autonegotiation once

Nothing writes a PHY register afterwards, only the read-only link monitor —
every `BMCR` write restarts autonegotiation. Some peers need 6–12 s to finish,
which is normal for 1000BASE-T.

If a port only reaches 100M, check the **cable and the peer port** first: both a
bad cable and a router LAN port that turned out not to be gigabit were measured
on this unit, neither had anything to do with the driver.

</details>

## Layout

```text
src/                 kernel module: switch / board (i2c) / mdio header
scripts/             netup, teardown, report, linkdiag, userspace tool
systemd/             vep1400.service, vep1400-net.service (+ userspace variant)
modprobe/            softdep and default parameters
initramfs/           optional early-load hook
vyos/                VyOS installer + boot hook
.github/workflows/   ping neodev.team after a push (its daily cron is the fallback)
install.sh           one entry point: module by default, --userspace for the tool
get.sh               the no-git one-liner (same file on GitHub and on the mirror)
```

## License

GPL-2.0, see [LICENSE](LICENSE). The register sequences come from public
documentation and from observing the vendor firmware; this project contains no
Dell or VMware code.
