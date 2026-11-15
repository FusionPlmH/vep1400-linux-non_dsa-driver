**English** &nbsp;·&nbsp; [简体中文](README.md)

# Dell VEP1400 / VMware Edge 610 — driver for stock Linux

Runs the **Dell VEP1400** (= **VMware SD-WAN Edge 610**, non-X, Intel Atom C3308)
with all six front panel RJ45 ports and both SFP cages on a **stock Debian /
Ubuntu / Proxmox VE / VyOS** — no custom kernel, no device tree, no DSA.

```
   GE1..GE3 ─┐
             ├─ 88E6190 port 10 ─ 802.1Q ─ X553 03:00.0 ─ eno1
   GE4..GE6 ─┤
             └─ 88E6190 port  9 ─ 802.1Q ─ X553 03:00.1 ─ eno2

   SFP1 = X553 05:00.1        SFP2 = X553 05:00.0
```

The driver bit-bangs the SMI bus over the Denverton P2SB pads that Dell's
firmware hides, configures the switch the way DiagOS does (one VLAN per front
panel port), powers the six PHYs up once and then leaves them entirely to
autonegotiation — plug a cable and it behaves like any other NIC. It also
disarms the PIC watchdog and enables SFP TX.

Measured on real hardware: all six ports at 1000 Mb/s, **918–926 Mbit/s** of TCP
payload per port.

## Quick start

Get a **management and internet path** first — installing needs headers and
packages, and loading the driver briefly disturbs the GE ports. This board has a
single management plane and is passively cooled, so **Wi-Fi is the easiest
choice**; never make a GE port your only management link during the install.

**VyOS** (native wireless configuration):

```
configure
set interfaces wireless wlan0 type station
set interfaces wireless wlan0 physical-device phy0
set interfaces wireless wlan0 ssid "<SSID>"
set interfaces wireless wlan0 security wpa mode wpa2
set interfaces wireless wlan0 security wpa passphrase "<PSK>"
set interfaces wireless wlan0 address dhcp
commit
save
```

**Debian / Proxmox VE** (ifupdown + wpasupplicant, PVE uses the same file):

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

**Ubuntu Server** (netplan — write `/etc/netplan/50-wifi.yaml`, then
`sudo netplan apply`):

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

(Replace `wlp2s0` with your actual wireless interface name — `ip -br link` lists
them.)

Confirm you are really online — these two commands work on Debian, PVE and VyOS
alike, and you do not need to know the interface name:

```sh
ip route get 1.1.1.1        # which interface the default route leaves through
ping -c1 deb.debian.org     # resolves and replies -> link, route and DNS are fine
```

Then the one-liner. The implementation is **chosen automatically**: Debian /
Ubuntu / PVE get the kernel module, VyOS gets the userspace one (it has no
compiler and no kernel headers):

```sh
GET=https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh
curl -fsSL $GET | sudo bash                     # automatic
curl -fsSL $GET | sudo bash -s -- --userspace   # force userspace (see the table)
```

No `curl`? Replace `curl -fsSL $GET` with `wget -qO- $GET`. GitHub slow? Use the
mirror (`VEP1400_TARBALL` points at a full archive):

```sh
curl -fsSL $GET | sudo VEP1400_TARBALL=https://neodev.team/vep1400-linux-non_dsa-driver.zip bash
```

With git:

```sh
git clone https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver.git
cd vep1400-linux-non_dsa-driver
sudo ./install.sh              # automatic; add --userspace to force the tool
```

| Option | Effect |
|---|---|
| *(none)* | auto-select: Debian/Ubuntu/PVE → kernel module + DKMS, VyOS → userspace |
| `--userspace` | force the userspace implementation: nothing compiled, no kernel taint |
| `--module` | force the kernel module (refused on VyOS) |
| `--initramfs` | also load the module from the initramfs (encrypted root, slow fsck) |
| `--no-dkms` | build for the running kernel only |
| `--no-start` | install and enable, do not start now |
| `--force` | replace the other implementation in place |

Uninstall: `sudo ./uninstall.sh` (removes the module, the userspace files under
`/usr`, and the VyOS files under `/config`)

## Which implementation?

| | kernel module `vep1400.ko` | userspace `vep1400-userspace.py` |
|---|---|---|
| Debian / Ubuntu / PVE | **selected automatically** (recommended) | force with `--userspace` |
| VyOS and other compiler-less systems | cannot be built | **selected automatically, the only option** |
| Kernel upgrades | DKMS rebuilds it | nothing to do |
| Needs | kernel headers + compiler | `python3` + readable `/dev/mem` |
| X553 speed strap | programmable | not programmable (not needed on this board) |
| Kernel taint | yes | no |

Both drive the same register sequences and reach the same throughput. Use
**one per machine** — `install.sh` refuses to mix them.

## Supported systems

| System | `install.sh` picks | Also needs | Status |
|---|---|---|---|
| Debian 13 | kernel module | `linux-headers-$(uname -r)` + `dkms` | ✅ tested (13.7 / kernel 6.12) |
| Debian 12 | kernel module | same | expected to work (kernel 6.1, untested) |
| Ubuntu 22.04 / 24.04 | kernel module | same | expected to work (kernel 5.15 / 6.8, untested) |
| Proxmox VE 8 / 9 | kernel module | `pve-headers-$(uname -r)` + `dkms` | expected to work (untested) |
| VyOS 1.3.4 | userspace | `python3` + readable `/dev/mem` | ✅ tested (1.3.4 / kernel 5.4.261) |
| other systemd distributions | userspace | same | untested |

- Any system can force the userspace implementation with `--userspace`: no
  compiler and no kernel headers required.
- Hardware support is limited to the **Dell VEP1400 / VMware SD-WAN Edge 610
  non-X (Atom C3308)**. The Edge 610X / VEP1400-X uses a C3558 and a different
  switch configuration, which this version does not handle.

## Port map

| Linux | Switch port | Uplink | VLAN |
|---|---|---|---|
| `GE1` `GE2` `GE3` | 1 2 3 | `eno1` (03:00.0) | 1 2 3 |
| `GE4` `GE5` `GE6` | 4 5 6 | `eno2` (03:00.1) | 4 5 6 |
| `SFP1` / `SFP2` | — | 05:00.1 / 05:00.0 | untagged |

`GE*` inherit their uplink's MAC plus a per-port offset (`+0x0a`…`+0x0f`).

## Using the ports

**Debian / Proxmox VE** (ifupdown):

```sh
# /etc/network/interfaces
auto GE1
iface GE1 inet dhcp
```

**VyOS**: it rejects interface names like `GE1` (`Invalid Ethernet interface
name`), so use native vifs on the two uplinks — `vif N` is front panel port N:

```
configure
set interfaces ethernet eth0 vif 3 address dhcp     # front panel 3
set interfaces ethernet eth1 vif 6 address dhcp     # front panel 6
commit
save
```

True on both:

- **Never** put an address on `eno1`/`eno2` — they are the tagged internal uplinks
- **Never** bridge two ports — they already share a broadcast domain, that loops
- Two ports on one subnet is fine; the driver sets `arp_ignore=1` / `arp_announce=2`

## Verify

```sh
sudo /usr/lib/vep1400/vep1400-report.sh        # one-page summary
sudo /usr/lib/vep1400/vep1400-linkdiag.sh 3    # decode one port's autonegotiation
```

On VyOS those two scripts are not under `/usr` (only `/config` survives an image
upgrade), so use the tool directly:

```sh
python3 /config/scripts/vep1400-userspace.py info      # switch port table
python3 /config/scripts/vep1400-userspace.py diag 3    # decode one port
python3 /config/scripts/vep1400-userspace.py watch 60  # follow link changes
```

A healthy boot looks like:

```
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

## The hardware

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

`dmidecode` is misleading here: `Max Speed: 2100 MHz` is the family ceiling the
BIOS fills in (the real maximum P-state is 1601 MHz, no turbo), `Upgrade: Socket
LGA775` is bogus (the CPU is soldered), and the four DIMM entries are just how the
firmware describes the SoC memory channels — the memory is onboard.

<details>
<summary><b>Why not DSA</b></summary>

Debian, Ubuntu, PVE and VyOS all ship kernels with `# CONFIG_NET_DSA is not set`
(VyOS disables `CONFIG_NET_SWITCHDEV` too), and the 88E6190 SMI bus is not wired
to any MDIO controller, so it cannot be described in ACPI or device tree either.
Rebuilding every target kernel is not an option, so the driver does what the
vendor firmware does: the switch becomes a set of 802.1Q access ports and Linux
sees six ordinary Ethernet interfaces.

The uplinks negotiate `1000baseKX/Full`, i.e. the switch and the X553s talk
1000BASE-X across the board. **2.5G never links** on this board (neither the X553
KR PHY nor the 88E6190 2500BASE-X PCS completes autonegotiation).

</details>

<details>
<summary><b>How the 1G link works (and what went wrong before)</b></summary>

- **The board strap is wrong**: after reset the PHYs come up with `1000BASE-T
  control (0x09) = 0x0e00`, i.e. manual master *and* manual slave — an invalid
  combination, so autonegotiation never completes. The driver rewrites it to
  `0x0200` (automatic).
- **The PHYs are powered down**: `BMCR = 0x1940`; the driver powers them up with
  `BMCR = 0x1140 | AN_RESTART`.
- **They are written exactly once, at load time**: every `BMCR` write restarts
  autonegotiation, so a driver that "helps" on cable insertion keeps killing the
  negotiation. An earlier fallback/forcing state machine did exactly that and made
  1G unreliable; it is gone. The link monitor is read-only.
- **Some peers need 6–12 s** — normal for 1000BASE-T, not a driver problem.
- Measured: 899–909 Mbit/s between two front panel ports, 927–931 Mbit/s to an
  RTL8153, 911–926 Mbit/s over 400 MB TCP; the VLAN split costs nothing
  measurable.

</details>

<details>
<summary><b>Module parameters</b></summary>

Set them in `/etc/modprobe.d/vep1400.conf` (a default file is installed):

| Parameter | Default | Meaning |
|---|---|---|
| `watchdog` | `1` | disarm the PIC watchdog |
| `sfp_tx` | `1` | clear `TX_DISABLE` on both SFP cages |
| `x553_speed` | `1000` | X553 backplane strap: `1000`, `2500`, or `0` (keep NVM) |
| `phy_speed` | `0` | `0` = autoneg, or force `10`/`100`/`1000` |
| `led_init` | `1` | program the front panel LEDs |
| `bus_num` | `-1` | iSMT bus number, `-1` = find by name |
| `p2sb_bar_addr` | `0` | P2SB MMIO BAR, `0` = autodetect |

```
softdep ixgbe pre: vep1400
options vep1400 watchdog=1 sfp_tx=1 x553_speed=1000 phy_speed=0 led_init=1
```

The `softdep` matters: the driver writes the X553 `NW_MNG_IF_SEL` strap and
`ixgbe` reads it exactly once at probe time. Most distributions keep `ixgbe` in
the initramfs, where it cannot be ordered first — `/sys/kernel/debug/vep1400/info`
then reports `x553_strap busy` and `vep1400-net.service` reloads `ixgbe` once.
Installing with `--initramfs` avoids that reload entirely.

</details>

## Layout

```
src/                 kernel module: switch / board (i2c) / mdio header
scripts/             netup, teardown, report, linkdiag, userspace tool
systemd/             vep1400.service, vep1400-net.service (+ userspace variant)
modprobe/            softdep and default parameters
initramfs/           optional early-load hook
vyos/                VyOS installer + boot hook
install.sh           one entry point: module by default, --userspace for the tool
get.sh               the no-git one-liner
```

## License

GPL-2.0, see [LICENSE](LICENSE). The register sequences come from public
documentation and from observing the vendor firmware; this project contains no
Dell or VMware code.
