**English** &nbsp;·&nbsp; [简体中文](README.zh-CN.md)

# vep1400 — Dell VEP1400 / VMware SD-WAN Edge 610 on standard Linux

Board support for the **Dell VEP1400** (sold as **VMware SD-WAN Edge 610**, the
non-X variant with an Intel Atom C3308 "Denverton") that makes the six front
panel RJ45 ports and the two SFP cages work on a stock **Debian / Ubuntu /
Proxmox VE / VyOS** installation — no custom kernel, no device tree, no DSA.

Tested on real hardware: Debian 13.7 / kernel 6.12, all six ports at 1000 Mb/s,
~930 Mb/s of useful throughput per port.

```
    ┌──────────────────────────── Edge 610 / VEP1400 ───────────────────────────┐
    │                                                                           │
    │  GE1 ─┐                                                                   │
    │  GE2 ─┼─ PHY1..3 ─┐                                                       │
    │  GE3 ─┘           │   Marvell 88E6190                                     │
    │                   ├─── port 10 ── 802.1Q ── 0000:03:00.0 (ixgbe) ── eno1  │
    │  GE4 ─┐           │                                                       │
    │  GE5 ─┼─ PHY4..6 ─┤                                                       │
    │  GE6 ─┘           └─── port  9 ── 802.1Q ── 0000:03:00.1 (ixgbe) ── eno2  │
    │                                                                           │
    │  SFP1 ── 0000:05:00.1 (ixgbe)     SFP2 ── 0000:05:00.0 (ixgbe)            │
    └───────────────────────────────────────────────────────────────────────────┘
```

`vep1400.ko` owns the switch: it bit-bangs the SMI bus over the hidden Denverton
P2SB pads, programs the 88E6190 into Dell DiagOS' "one VLAN per front panel
port" model, powers up the six PHYs and then leaves them completely alone, so a
plugged cable autonegotiates its highest common speed in 2–6 s — exactly like a
normal NIC. It also disarms the PIC watchdog and enables SFP TX.

`vep1400-net.service` then creates `GE1`…`GE6` as VLAN devices on top of the two
uplinks and renames the SFP cages to `SFP1`/`SFP2`.

---

## Before you install: bring up your management path first

Installing this driver is a chicken-and-egg problem. `vep1400.ko` resets the
switch and re-initialises all six front panel PHYs, and `vep1400-net.service`
reloads `ixgbe` once when it has to. Any address on a `GE*` port disappears
during that window — and you need internet access to install `dkms` and
`linux-headers-$(uname -r)` *before* the driver can even be built.

**Recommended: use the Wi-Fi card as your management and internet path, then
install the driver.** Wi-Fi is completely independent of the 88E6190 and the
X553, so the box stays reachable — and keeps its internet access — through the
whole install and every reboot afterwards. The reference unit has a QCA986x
(`ath10k_pci`) card. If your unit has no Wi-Fi, a USB Ethernet adapter or a
second machine on the serial console works just as well.

What does **not** work is making one of `GE1`…`GE6` your only management link
before the driver exists.

Pick the recipe that matches your install:

**NetworkManager** (desktop images, Proxmox VE):

```sh
nmcli device wifi connect "<SSID>" password "<PSK>"
nmcli connection modify "<SSID>" connection.autoconnect yes
```

**iwd**:

```sh
iwctl --passphrase "<PSK>" station wlan0 connect "<SSID>"
```

**Minimal Debian (ifupdown + wpasupplicant)** — this is what the reference unit
runs:

```sh
apt install -y wpasupplicant
cat >> /etc/network/interfaces <<'EOF'

allow-hotplug wlp2s0
iface wlp2s0 inet dhcp
	wpa-ssid <SSID>
	wpa-psk  <PSK>
EOF
ifup wlp2s0
```

Check the interface name first with `ip -br link` — it is `wlp2s0` here, but
`wlan0` on many other cards. Then confirm you are really online before you
continue:

```sh
ip -4 addr show wlp2s0     # an address
ip route                   # a default route via wlp2s0
ping -c1 deb.debian.org    # replies
```

Now go ahead and install. Keep the serial console attached for the first reboot,
and do not configure `GE1`…`GE6` until `vep1400-net.service` has created them.

## Quick start

### 1. One command — no git, no download

```sh
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh | sudo bash
```

If `curl` is not installed, `wget` does the same thing:

```sh
wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh | sudo bash
```

Add `--initramfs` for the cleanest boot (see [install options](#install-options)):

```sh
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo bash -s -- --initramfs

wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo bash -s -- --initramfs
```

`get.sh` downloads the release archive, unpacks it in a temporary directory and
runs `install.sh`. It accepts every `install.sh` option and honours these
environment variables if you mirror the project somewhere else:

| Variable | Default | Meaning |
|---|---|---|
| `VEP1400_BASE` | `https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver` | repository base URL |
| `VEP1400_REF` | `main` | branch to download |
| `VEP1400_TARBALL` | *(unset)* | full archive URL (`.tar.gz` or `.zip`), overrides both |

**Mirror** — <https://neodev.team/vep1400-linux-non_dsa-driver.zip> is a full copy
of this repository. Use it when GitHub is slow or blocked; the same one-liner
just points `VEP1400_TARBALL` at it:

```sh
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo VEP1400_TARBALL=https://neodev.team/vep1400-linux-non_dsa-driver.zip bash

wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo VEP1400_TARBALL=https://neodev.team/vep1400-linux-non_dsa-driver.zip bash
```

### 2. With git

```sh
sudo apt install -y dkms linux-headers-$(uname -r)
git clone https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver.git
cd vep1400-linux-non_dsa-driver
sudo ./install.sh
sudo reboot
```

## Requirements

| | |
|---|---|
| Hardware | Dell VEP1400 / VMware SD-WAN Edge 610 (non-X) |
| OS | Debian 12/13, Ubuntu 22.04/24.04, Proxmox VE 8/9 (kernel module); VyOS (userspace, see [VyOS](#vyos)) |
| Kernel | Debian/Ubuntu/PVE: 5.15 – 6.x, headers installed (`linux-headers-$(uname -r)`) |
| Management | an independent path with internet access — Wi-Fi, a USB NIC or the serial console (see [above](#before-you-install-bring-up-your-management-path-first)) |
| Tools | `dkms` (recommended, optional), `curl` or `wget`, `i2c-tools` (diagnostics only) |

Boards with the Intel Atom C3XX8 **(Edge 6X0 / VEP1400-X)** use a different
switch configuration and are **not** supported by this version.

## The hardware

Everything below was read from a real unit with `dmidecode`, `lspci` and
`lscpu`, not from a marketing sheet.

| | |
|---|---|
| System | Dell EMC `EDGE610`, DMI family `VEP1400`, SKU `08VT73`, BIOS `3.43.0.9-8` |
| Board | `EDGE610-CPU` |
| CPU | Intel Atom C3308 (Denverton, 14 nm), 2 cores / 2 threads, 1.6 GHz base, 2.1 GHz burst, 4 MB L2, QAT at `01:00.0` |
| Memory | 4 GB DDR4-2400 ECC UDIMM (trained at 1866 MT/s), 4 slots, 128 GB max |
| Storage | 16 GB eMMC (`mmcblk0`) plus an SD slot and one SATA port |
| Switch | Marvell 88E6190 rev 1 — 6 front panel PHYs + 2 SerDes ports used as CPU uplinks |
| NICs | 4× Intel X553 Backplane `8086:15c3`: `03:00.0/.1` feed the switch, `05:00.0/.1` are the SFP cages |
| Wi-Fi | QCA986x `ath10k_pci` at `02:00.0` on the reference unit — ideal as the management path |
| Front panel | 6× 10/100/1000BASE-T RJ45, 2× SFP |
| Console | `ttyS0`, 115200 8N1 |
| Cooling | **passive — there is no fan and no fan controller on the SMBus** |
| Watchdog | PIC on SMBus `0x22`/`0x24`, reboots the board 4–5 minutes after power-on unless disarmed |

The uplinks negotiate `1000baseKX/Full`, i.e. the switch and the X553s talk
1000BASE-X across the board. 2.5G does not link on this board (see
[the 1G story](#how-the-1g-link-works)).

## Port map and MAC addresses

| Linux | Switch port | PHY | Uplink | VLAN |
|---|---|---|---|---|
| `GE1` | 1 | 1 | `eno1` (03:00.0, port 10) | 1 |
| `GE2` | 2 | 2 | `eno1` | 2 |
| `GE3` | 3 | 3 | `eno1` | 3 |
| `GE4` | 4 | 4 | `eno2` (03:00.1, port 9) | 4 |
| `GE5` | 5 | 5 | `eno2` | 5 |
| `GE6` | 6 | 6 | `eno2` | 6 |
| `SFP1` | — | — | `05:00.1` | untagged |
| `SFP2` | — | — | `05:00.0` | untagged |

`GE1`…`GE6` inherit their uplink's MAC address plus a per-port offset
(`+0x0a … +0x0f`) so every interface has a unique address.

## Why not DSA?

The upstream `mv88e6xxx` DSA driver would be the natural fit, but Debian,
Ubuntu, Proxmox VE and VyOS all ship kernels with `# CONFIG_NET_DSA is not set`
(verify with `grep NET_DSA /boot/config-$(uname -r)`), and the 88E6190 SMI bus
is not connected to any MDIO controller, so the switch cannot be described in
ACPI or device tree either. Rebuilding every target kernel is not an option for
a downloadable driver, therefore this module does what the vendor firmware does:
it configures the switch as a set of VLAN access ports and lets Linux see six
ordinary Ethernet interfaces.

```
GE1..GE3 -> eno1 (03:00.0) -> switch port 10, VLAN 1..3
GE4..GE6 -> eno2 (03:00.1) -> switch port  9, VLAN 4..6
```

Each front panel port is a secure 802.1Q access port; the CPU links carry the
tags and are never configured with an address.

## Install options

```sh
sudo ./install.sh              # DKMS build + install, enable and start the services
sudo ./install.sh --no-start   # install + enable, do not start now (reboot to use)
sudo ./install.sh --no-dkms    # build only for the running kernel, no DKMS
sudo ./install.sh --initramfs  # also load the module from the initramfs
```

Install with `--initramfs` when the root filesystem takes a long time to mount
(encrypted root, fsck): the PIC watchdog reboots the board 4–5 minutes after
power-on unless the module has disarmed it. It also makes the uplink strap apply
*before* `ixgbe` probes, so the boot does not need a NIC reload — see
[How the 1G link works](#how-the-1g-link-works).

To remove everything:

```sh
sudo ./uninstall.sh
```

## VyOS

VyOS is a special case: the image ships **no compiler and no kernel headers**
(`/lib/modules/$(uname -r)/build` only holds a handful of UAPI headers), so
`vep1400.ko` cannot be built there — and VyOS has no DKMS to rebuild it on
kernel updates anyway. The same register sequences are therefore also available
as a **userspace tool** that needs neither: it drives the switch directly
through `/dev/mem` (the bit-banged SMI bus on the P2SB pads) and `/dev/i2c-0`
(watchdog and SFP TX).

Verified on **VyOS 1.3.4 (equuleus), kernel 5.4.261-amd64-vyos**, where
`CONFIG_NET_DSA` and `CONFIG_NET_SWITCHDEV` are both disabled — the VLAN split
below is the only option, exactly as on Debian.

```sh
git clone https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver.git
cd vep1400-linux-non_dsa-driver
sudo ./vyos/setup.sh
```

`vyos/setup.sh` does four things:

1. copies `vep1400-userspace.py` to `/config/scripts/`, which VyOS keeps across
   image upgrades (the rest of the filesystem does not),
2. installs `/config/scripts/vyos-postconfig-bootup.script`, the documented
   VyOS hook that runs on every boot after the configuration is applied,
3. loads `i2c_ismt` and `i2c-dev`,
4. programs the switch right away.

The boot hook is what makes it survive reboots. It was validated the hard way:
reset the switch to its power-on defaults (uplinks down, `eth0: Link detected:
no`), reboot, and the hook brings everything back:

```
$ journalctl -t vep1400 -b
vyos vep1400[2275]: switch and front panel PHYs configured

$ ethtool eth0 | grep 'Link detected'
Link detected: yes
```

Configure the front panel ports as VLAN interfaces on the two uplinks. VyOS
names them `eth0`/`eth1`, and `vif N` maps 1:1 onto front panel port N:

```
configure
set interfaces ethernet eth0 vif 1 address 192.168.10.1/24    # front panel 1
set interfaces ethernet eth0 vif 2 address 192.168.20.1/24    # front panel 2
set interfaces ethernet eth0 vif 3 address dhcp               # front panel 3
set interfaces ethernet eth1 vif 4 address 192.168.40.1/24    # front panel 4
set interfaces ethernet eth1 vif 5 address 192.168.50.1/24    # front panel 5
set interfaces ethernet eth1 vif 6 address dhcp               # front panel 6
commit
save
```

The result is `eth0.1` … `eth1.6`, one per front panel port. Never put an address
on `eth0`/`eth1` themselves.

Measured on the reference unit: front panel port 3 at **1000 Mb/s full duplex**
(`bmsr=0x796d`, `lpar=0x4de1`, switch port status `0x5e4f`), and **926 Mbit/s**
of TCP payload over `eth0.3` — identical to the kernel-module numbers on
Debian, so the userspace tool costs nothing.

Day-to-day commands:

```sh
python3 /config/scripts/vep1400-userspace.py info    # switch port table
python3 /config/scripts/vep1400-userspace.py phy     # PHY registers + link
python3 /config/scripts/vep1400-userspace.py init    # re-run the bring-up
python3 /config/scripts/vep1400-userspace.py reset   # back to power-on defaults
```

If you have a spare cable and want `GE1`…`GE6` names instead of `eth0.N`, the
tool can create them too (`... vep1400-userspace.py vlan`), but on VyOS the
`vif` form above is the idiomatic one.

> The userspace tool is also handy for **diagnosing** a Debian/Ubuntu/PVE
> install (`info` and `phy` work while the module is loaded). Do not run `init`
> there — the module owns the switch. Pick one mechanism per machine.

## Using the ports

`vep1400-net.service` runs at boot and creates `GE1`…`GE6`. Configure them like
any other interface, for example with `/etc/network/interfaces`:

```
auto GE1
iface GE1 inet dhcp
```

or NetworkManager:

```sh
nmcli con add type ethernet ifname GE1 con-name GE1 ipv4.method auto
```

> **Never** assign an address to `eno1`/`eno2`. They are the internal switch
> uplinks and carry tagged traffic only.
>
> **Never** bridge two `GE*` interfaces together. They already share one
> broadcast domain through the switch (only the VLAN keeps them apart), so a
> bridge creates a loop.

Two ports on the same subnet are fine, but Linux keeps a single route per
subnet — the driver already sets `arp_ignore=1` and `arp_announce=2` on the
`GE*` devices so replies leave through the port the request arrived on.

## Verify

```sh
sudo /usr/lib/vep1400/vep1400-report.sh
```

A healthy boot looks like this:

```
vep1400: iSMT bus 0 (SMBus iSMT adapter at dfe3c000)
vep1400: PIC watchdog disarmed
vep1400: P2SB hidden by firmware, BAR 0x00000000fd000000 from iomem
vep1400: Marvell 88E6190 rev 1
vep1400: X553 fn0 NW_MNG_IF_SEL 0x00102002 -> 0x02082002 (1000M)
vep1400: X553 fn1 NW_MNG_IF_SEL 0x00102002 -> 0x02082002 (1000M)
vep1400: GE1 -> VLAN 1 via CPU port 10
...
vep1400: CPU port 10 link up (1G)
vep1400: CPU port 9 link up (1G)
vep1400: front panel PHYs powered up, autonegotiation running
vep1400: switch ready
vep1400: GE3 link up (1G)
vep1400: GE6 link up (1G)
```

`/sys/kernel/debug/vep1400/info` summarises the driver state, including whether
the X553 strap could be applied:

```
switch_id    0x1901 (88E6190 rev 1)
x553_speed   1000
x553_strap   applied
phy_speed    0
led_init     1
cpu_port_10   up
cpu_port_9    up
```

`/sys/kernel/debug/vep1400/ports` shows every switch port (`up`/`down` is the
switch's own view):

```
port status mac_ctl ctl0 pvid ctl2 led link
0    0x0d00 0x0003  0x007c 1    0x2080 0x0000 up
1    0x100f 0x0003  0x007f 1    0x2c80 0x0030 down
...
3    0x5e4f 0x0003  0x007f 3    0x2c80 0x0030 up
6    0x1e0f 0x0003  0x007f 6    0x2c80 0x0030 up
9    0x0e49 0x203e  0x007f 1    0x2c80 0x0022 up
10   0x0e49 0x203e  0x007f 1    0x2c80 0x0022 up
```

Is a single port suspicious?

```sh
sudo /usr/lib/vep1400/vep1400-linkdiag.sh 3
```

```
port 3: link up  speed=1G  duplex=full  an=on  an-complete=yes
  local: anar=0x05e1 1000t-ctrl=0x0200 -> [100FD 100HD 10FD 10HD 1000FD]
  peer : anlpar=0x4de1 (10/100), 1000t-status=0x7800 -> [100FD 100HD 10FD 10HD]
```

It prints both sides' autonegotiation advertisement, which immediately shows
whether the peer is a 10/100-only device or the cable is bad.

## Module parameters

Set them in `/etc/modprobe.d/vep1400.conf` (a default file is installed):

| Parameter | Default | Meaning |
|---|---|---|
| `watchdog` | `1` | Disarm the PIC watchdog. Without it the board reboots every 4–5 minutes. |
| `sfp_tx` | `1` | Clear `TX_DISABLE` on both SFP cages (board CPLD 0x31). |
| `x553_speed` | `1000` | X553 backplane strap: `1000`, `2500` or `0` (keep the NVM value). |
| `phy_speed` | `0` | `0` = front panel autonegotiation. `10`/`100`/`1000` force a speed. |
| `led_init` | `1` | Program the front panel LED registers. |
| `bus_num` | `-1` | iSMT bus number for the watchdog/SFP I²C; `-1` = find it by name. |
| `p2sb_bar_addr` | `0` | P2SB MMIO BAR; `0` = autodetect (normally works). |

Contents of `/etc/modprobe.d/vep1400.conf`:

```
softdep ixgbe pre: vep1400
options vep1400 watchdog=1 sfp_tx=1 x553_speed=1000 phy_speed=0 led_init=1
```

The `softdep` matters: the driver programs the X553 `NW_MNG_IF_SEL` strap, and
`ixgbe` reads that strap exactly once when it probes. Loading `vep1400` first
means the uplinks come up at 1G without unloading anything.

Most distributions keep `ixgbe` inside the initramfs, where the module cannot be
ordered first — `/sys/kernel/debug/vep1400/info` then reports `x553_strap busy`,
and `vep1400-net.service` reloads `ixgbe` once during boot (before any address
is configured, so nothing notices). Installing with `--initramfs` avoids that:
`vep1400` is then already loaded inside the initramfs and the strap is applied
before `ixgbe` binds.

If you load the module by hand after `ixgbe` is already up, reload the NIC
driver yourself:

```sh
sudo modprobe -r ixgbe && sudo modprobe ixgbe
```

## How the 1G link works

Getting a reliable gigabit link took some reverse engineering, and the details
are worth knowing when something misbehaves:

* **The board strap is wrong.** The front panel PHYs come out of reset with
  `1000BASE-T control (reg 0x09) = 0x0e00`, i.e. *manual master* **and**
  *manual slave* at the same time. Autonegotiation then never completes and the
  port falls back. The driver rewrites it to `0x0200` (automatic
  master/slave).
* **The PHYs are powered down.** `BMCR = 0x1940` after reset. The driver powers
  them up once with `BMCR = 0x1140 | AN_RESTART`.
* **The PHYs are written exactly once, at load time.** Every `BMCR` write
  restarts autonegotiation, so a driver that "helps" during cable insertion
  keeps killing the negotiation it is trying to speed up. A former
  fallback/forcing state machine did exactly that and made 1G links unreliable;
  it is gone. The link monitor is read-only.
* **Some peers need 6–12 s.** That is normal for 1000BASE-T autonegotiation and
  is not a driver problem. The kernel log reports the transition, and
  `vep1400-linkdiag.sh` shows whether the peer advertises 1000BASE-T at all.
* **2.5G does not link on this board.** Neither the X553 KR PHY nor the
  88E6190 2500BASE-X PCS completes autonegotiation in that mode. Leave
  `x553_speed=1000`.

Measured on the reference unit: 899–909 Mbit/s between two front panel ports
(loop cable), 927–931 Mbit/s to an RTL8153 USB NIC, and 911 Mbit/s of payload
over a 400 MB TCP transfer — the VLAN split costs nothing measurable.

## Troubleshooting

**`GE1`…`GE6` are missing.**
`systemctl status vep1400-net` and `journalctl -u vep1400-net`. The script loads
`ixgbe` if needed and then needs `eno1` and `eno2`; if `ixgbe` had already
probed before the strap was applied, `/sys/kernel/debug/vep1400/info` reports
`x553_strap busy` and the script reloads `ixgbe` once by itself.

**`vep1400: unexpected switch id`.**
The SMI read is out of sync. Check `dmesg | grep 'P2SB'`: the BAR should be
`0xfd000000`-ish and `north reg0` must not be `0xffffffff`. On unusual
firmware versions pass `p2sb_bar_addr=` explicitly.

**`vep1400: no iSMT SMBus adapter`.**
`i2c_ismt` did not load. `modprobe i2c_ismt`, or pass `bus_num=<n>`. Without it
only the watchdog and SFP TX are skipped; the ports still work — but the board
will reboot after 4–5 minutes.

**The board reboots every few minutes.**
The watchdog was not disarmed: `watchdog=1`, and the module must load early
(correct `softdep` + `vep1400.service` enabled).

**A port links at 100 Mbps.**
Run `vep1400-linkdiag.sh <n>`. If the peer also advertises 1000BASE-T, the cable
or the peer's port is the problem — this board has been seen to negotiate 100M
with a marginal cable and with a router LAN port that turned out not to be
gigabit.

**LEDs are dark.**
`led_init=1` (default). The parameter is read-only; to re-run the programming
reload the module (`modprobe -r vep1400 && modprobe vep1400`).

**Nothing works after a kernel upgrade.**
That is what DKMS is for; check `dkms status` and `journalctl -u dkms`. Without
`--no-dkms` the module is rebuilt automatically for the new kernel.

## Layout

```
src/vep1400_switch.c   88E6190 bring-up, X553 strap, PHYs, LEDs, link monitor, debugfs
src/vep1400_board.c    I²C: PIC watchdog, SFP TX_DISABLE
src/vep1400_mdio.h     P2SB pads, bit-banged SMI, VTU/SERDES/PHY helpers
scripts/               netup, teardown, report, linkdiag
scripts/vep1400-userspace.py
                       the same bring-up without a kernel module (VyOS)
vyos/setup.sh          installs the userspace tool + the VyOS boot hook
vyos/vyos-postconfig-bootup.script
systemd/               vep1400.service, vep1400-net.service
modprobe/vep1400.conf  softdep + default parameters
initramfs/             optional early-load hook
get.sh                 download-and-install without git
```

The driver is intentionally small and read-only after load: 3 s link polling of
the PHY status registers, a few debugfs files, and no timer touches hardware.

## Notes

* The board is **passively cooled** — there is no fan and no fan controller on
  the SMBus (no device at 0x1b). CPU temperature comes from the CPU's own
  `coretemp` sensor, ~47–50 °C idle.
* Front panel PHYs, switch and uplinks are configured once. A cable move, a
  speed change or a peer reboot is handled by the PHYs' own state machine.
* Register sequences were derived from publicly available documentation and
  from observing the vendor firmware; this project contains no Dell or VMware
  code.

## License

GPL-2.0 — see [LICENSE](LICENSE).
