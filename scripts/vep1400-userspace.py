#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Dell VEP1400 / VMware SD-WAN Edge 610 - userspace switch bring-up.

Same register sequences as vep1400.ko, but executed from userspace through
/dev/mem and /dev/i2c-N.  Use it where the kernel module cannot be built, for
example on VyOS (no compiler, no kernel headers in the image).

  vep1400-userspace.py info          show switch state (read only)
  vep1400-userspace.py init          configure switch, PHYs, LEDs, watchdog, SFP
  vep1400-userspace.py reset         reset the switch to its power-on defaults
  vep1400-userspace.py phy           dump the front panel PHY registers
  vep1400-userspace.py diag [n]      decode one port's autonegotiation
  vep1400-userspace.py watch [sec]   follow link changes (default 60 s)

Options:
  --reset        reset the switch first (drops all links for ~1s)
  --no-i2c       skip watchdog / SFP handling
  --force        allow init/reset even when vep1400.ko owns the switch

Which one to use: on Debian/Ubuntu/PVE prefer the kernel module (it survives
kernel upgrades through DKMS and can program the X553 strap). This tool is for
systems where the module cannot be built - VyOS, appliances, immutable images -
and for diagnostics.
"""

import ctypes
import fcntl
import mmap
import os
import struct
import sys
import time

# --------------------------------------------------------------------------
# hardware constants (from src/vep1400_mdio.h and src/vep1400_switch.c)

P2SB_NORTH_OFF = 0x00C20000
P2SB_NORTH_LEN = 0x10000

PIN_SW_RESET = 1
PIN_MDC = 33
PIN_MDIO = 34

PAD_TXSTATE = 1 << 0
PAD_RXSTATE = 1 << 1
PAD_TXDIS = 1 << 8
PAD_RXDIS = 1 << 9
PAD_PMODE = 0x7 << 10

SMI_GLOBAL1 = 0x1B
SMI_GLOBAL2 = 0x1C

REG_PORT_STS = 0x00
REG_PORT_MAC = 0x01
REG_SWITCH_ID = 0x03
REG_PORT_CTL0 = 0x04
REG_PORT_VID = 0x07
REG_PORT_CTL2 = 0x08
REG_PORT_LED = 0x16

G1_VTU_FID = 0x02
G1_VTU_OP = 0x05
G1_VTU_VID = 0x06
G1_VTU_DATA1 = 0x07
G1_VTU_DATA2 = 0x08
VTU_OP_BUSY = 0x8000
VTU_OP_LOAD = 0xB000
VTU_VID_VALID = 0x1000

G2_SMI_CMD = 0x18
G2_SMI_DATA = 0x19
G2_BUSY = 0x8000
G2_C45_WRITE = 0x0400
G2_C45_READ = 0x0C00
G2_C22_MODE = 0x1000
G2_C22_WRITE = 0x0400
G2_C22_READ = 0x0800
MMD_PHYXS = 4

SERDES_BMCR = 0x2000
SERDES_ADV = 0x2004
SERDES_ADV_VALUE = 0x00E0

PHY_BMCR = 0x00
PHY_BMSR = 0x01
PHY_CTRL1000 = 0x09
PHY_PAGE_REG = 0x16
PHY_ADV_1000FD = 0x0200
BMCR_AN_ENABLE = 0x1000
BMCR_AN_RESTART = 0x0200
BMCR_SPEED_1000 = 0x0040
BMCR_FULL_DUPLEX = 0x0100

MAC_CTL_CPU = 0x203E
CTL0_FORWARDING = 0x007F
CTL2_8021Q = 0x2C80
LED_VALUE = 0x8030
CMODE_1000BASE_X = 0x09

FIRST_PORT, LAST_PORT = 1, 6
CPU_PORT_A, CPU_PORT_B = 10, 9
PORTS_PER_UPLINK = 3

I2C_PIC = 0x22
I2C_PIC2 = 0x24
I2C_CPLD = 0x31
CPLD_SFP = (0x10, 0x11)
CPLD_TX_DISABLE = 0x80

I2C_SLAVE = 0x0703
I2C_SMBUS = 0x0720
I2C_SMBUS_READ = 1
I2C_SMBUS_WRITE = 0
I2C_SMBUS_BYTE_DATA = 2


# --------------------------------------------------------------------------
# error helper


class Error(Exception):
    pass


def die(msg):
    sys.stderr.write("vep1400: ERROR: %s\n" % msg)
    sys.exit(1)


# --------------------------------------------------------------------------
# P2SB / SMI


def find_p2sb():
    """Locate the hidden P2SB window through /proc/iomem."""
    try:
        with open("/proc/iomem") as f:
            lines = f.readlines()
    except IOError:
        raise Error("/proc/iomem not readable")

    for line in lines:
        if "INTC3000" not in line:
            continue
        span = line.split()[0]
        start, end = [int(x, 16) for x in span.split("-")]
        if (end - start + 1) != P2SB_NORTH_LEN:
            continue
        if (start - P2SB_NORTH_OFF) & 0xFFFFFF:
            continue
        return start - P2SB_NORTH_OFF
    raise Error("P2SB window not found in /proc/iomem")


class Smi(object):
    def __init__(self, verbose=False):
        self.verbose = verbose
        self.bar = find_p2sb()
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        try:
            self.north = mmap.mmap(self.fd, P2SB_NORTH_LEN, mmap.MAP_SHARED,
                                   mmap.PROT_READ | mmap.PROT_WRITE,
                                   offset=self.bar + P2SB_NORTH_OFF)
        except PermissionError:
            os.close(self.fd)
            raise Error("/dev/mem cannot map the P2SB window at 0x%x: the "
                        "kernel blocks it with CONFIG_IO_STRICT_DEVMEM, use "
                        "the kernel module instead"
                        % (self.bar + P2SB_NORTH_OFF))
        self.padbar = struct.unpack_from("<I", self.north, 0x0C)[0]
        if self.padbar >= P2SB_NORTH_LEN:
            raise Error("P2SB north window not decodable (padbar 0x%x)"
                        % self.padbar)
        self.pad_off = self.padbar

    def close(self):
        self.north.close()
        os.close(self.fd)

    # -- pads ------------------------------------------------------------
    def _pad_read(self, pin):
        return struct.unpack_from("<I", self.north, self.pad_off + pin * 8)[0]

    def _pad_write(self, pin, val):
        struct.pack_into("<I", self.north, self.pad_off + pin * 8, val)

    def pad_input(self, pin):
        v = self._pad_read(pin)
        v &= ~PAD_PMODE
        v &= ~PAD_RXDIS
        v |= PAD_TXDIS
        self._pad_write(pin, v)

    def pad_output(self, pin, high):
        v = self._pad_read(pin)
        v &= ~PAD_PMODE
        v &= ~(PAD_TXDIS | PAD_RXDIS | PAD_TXSTATE)
        if high:
            v |= PAD_TXSTATE
        self._pad_write(pin, v)

    def pad_value(self, pin):
        return 1 if (self._pad_read(pin) & PAD_RXSTATE) else 0

    # -- bit banging -----------------------------------------------------
    def mdc(self, high):
        self.pad_output(PIN_MDC, high)

    def mdio_drive(self, high):
        if high:
            self.pad_input(PIN_MDIO)
        else:
            self.pad_output(PIN_MDIO, 0)

    def mdio_bit(self, bit):
        self.mdc(0)
        self.mdio_drive(bit)
        self.mdc(1)

    def mdio_sample(self):
        self.mdc(0)
        self.mdio_drive(1)
        self.mdc(1)
        return self.pad_value(PIN_MDIO)

    def _header(self, phy, reg, write):
        for _ in range(32):
            self.mdio_bit(1)
        self.mdio_bit(0)
        self.mdio_bit(1)
        self.mdio_bit(0 if write else 1)
        self.mdio_bit(1 if write else 0)
        for i in range(4, -1, -1):
            self.mdio_bit((phy >> i) & 1)
        for i in range(4, -1, -1):
            self.mdio_bit((reg >> i) & 1)

    def read(self, phy, reg):
        raw = 0
        self._header(phy, reg, False)
        self.mdio_sample()          # turnaround
        self.mdio_sample()          # ack (not reliable on this board)
        for i in range(15, -1, -1):
            raw |= self.mdio_sample() << i
        self.mdc(0)
        self.mdio_drive(1)
        return raw >> 1             # this board returns the data one bit early

    def write(self, phy, reg, value):
        self._header(phy, reg, True)
        self.mdio_bit(1)
        self.mdio_bit(0)
        for i in range(15, -1, -1):
            self.mdio_bit((value >> i) & 1)
        self.mdc(0)
        self.mdio_drive(1)

    def update(self, phy, reg, clear, set_):
        v = self.read(phy, reg)
        v = (v & ~clear) | set_
        self.write(phy, reg, v)
        return v

    def wait_idle(self, phy, reg, mask, retries=100):
        for _ in range(retries):
            if not (self.read(phy, reg) & mask):
                return
            time.sleep(0.0001)
        raise Error("switch register 0x%02x stayed busy" % reg)

    # -- switch tables ---------------------------------------------------
    def vtu_load(self, vid, fid, data1, data2):
        self.write(SMI_GLOBAL1, G1_VTU_FID, fid)
        self.write(SMI_GLOBAL1, G1_VTU_VID, VTU_VID_VALID | vid)
        self.write(SMI_GLOBAL1, G1_VTU_DATA1, data1)
        self.write(SMI_GLOBAL1, G1_VTU_DATA2, data2)
        self.write(SMI_GLOBAL1, G1_VTU_OP, VTU_OP_LOAD)
        self.wait_idle(SMI_GLOBAL1, G1_VTU_OP, VTU_OP_BUSY)

    def _g2_addr(self, port, reg):
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)
        self.write(SMI_GLOBAL2, G2_SMI_DATA, reg)
        self.write(SMI_GLOBAL2, G2_SMI_CMD,
                   G2_BUSY | (port << 5) | MMD_PHYXS)
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)

    def serdes_read(self, port, reg):
        self._g2_addr(port, reg)
        self.write(SMI_GLOBAL2, G2_SMI_CMD,
                   G2_BUSY | G2_C45_READ | (port << 5) | MMD_PHYXS)
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)
        return self.read(SMI_GLOBAL2, G2_SMI_DATA)

    def serdes_write(self, port, reg, value):
        self._g2_addr(port, reg)
        self.write(SMI_GLOBAL2, G2_SMI_DATA, value)
        self.write(SMI_GLOBAL2, G2_SMI_CMD,
                   G2_BUSY | G2_C45_WRITE | (port << 5) | MMD_PHYXS)
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)

    # -- switch internal PHYs (indirect clause 22) -----------------------
    def phy_read(self, port, reg):
        cmd = (G2_BUSY | G2_C22_MODE | G2_C22_READ |
               ((port & 0x1F) << 5) | (reg & 0x1F))
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)
        self.write(SMI_GLOBAL2, G2_SMI_CMD, cmd)
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)
        return self.read(SMI_GLOBAL2, G2_SMI_DATA)

    def phy_write(self, port, reg, value):
        cmd = (G2_BUSY | G2_C22_MODE | G2_C22_WRITE |
               ((port & 0x1F) << 5) | (reg & 0x1F))
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)
        self.write(SMI_GLOBAL2, G2_SMI_DATA, value)
        self.write(SMI_GLOBAL2, G2_SMI_CMD, cmd)
        self.wait_idle(SMI_GLOBAL2, G2_SMI_CMD, G2_BUSY)

    def phy_write_page(self, port, page, reg, value):
        self.phy_write(port, PHY_PAGE_REG, page)
        self.phy_write(port, reg, value)


# --------------------------------------------------------------------------
# i2c


class I2cSmbusData(ctypes.Union):
    _fields_ = [("byte", ctypes.c_uint8),
                ("word", ctypes.c_uint16),
                ("block", ctypes.c_uint8 * 34)]


class I2cSmbusIoctl(ctypes.Structure):
    _fields_ = [("read_write", ctypes.c_uint8),
                ("command", ctypes.c_uint8),
                ("size", ctypes.c_uint32),
                ("data", ctypes.POINTER(I2cSmbusData))]


def i2c_find_bus(name="iSMT"):
    base = "/sys/bus/i2c/devices"
    try:
        entries = sorted(os.listdir(base))
    except OSError:
        raise Error("no i2c buses (modprobe i2c_ismt i2c-dev)")
    for e in entries:
        p = os.path.join(base, e, "name")
        try:
            with open(p) as f:
                n = f.read().strip()
        except IOError:
            continue
        if name.lower() in n.lower():
            return int(e.split("-")[1])
    raise Error("i2c bus %s not found" % name)


def i2c_open(bus):
    return os.open("/dev/i2c-%d" % bus, os.O_RDWR)


def smbus(fd, addr, read, size, command, value=0):
    """The iSMT controller only implements SMBus transactions, not plain I2C,
    so every access has to go through I2C_SMBUS."""
    data = I2cSmbusData()
    if not read and size == I2C_SMBUS_BYTE_DATA:
        data.byte = value
    args = I2cSmbusIoctl(read, command, size, ctypes.pointer(data))
    fcntl.ioctl(fd, I2C_SLAVE, addr)
    fcntl.ioctl(fd, I2C_SMBUS, bytearray(ctypes.string_at(
        ctypes.addressof(args), ctypes.sizeof(args))))
    if not read:
        return None
    return data.word if size != I2C_SMBUS_BYTE_DATA else data.byte


def smbus_write_byte_data(fd, addr, reg, value):
    smbus(fd, addr, I2C_SMBUS_WRITE, I2C_SMBUS_BYTE_DATA, reg, value)


def smbus_read_byte_data(fd, addr, reg):
    return smbus(fd, addr, I2C_SMBUS_READ, I2C_SMBUS_BYTE_DATA, reg)


# --------------------------------------------------------------------------
# board bring-up


def switch_reset(smi):
    smi.pad_output(PIN_MDC, 0)
    smi.pad_input(PIN_MDIO)
    smi.pad_output(PIN_SW_RESET, 0)
    time.sleep(0.1)
    smi.pad_output(PIN_SW_RESET, 1)
    time.sleep(0.5)


def switch_id(smi):
    return smi.read(0, REG_SWITCH_ID)


def vtu_data1(untagged_port):
    return (0xFFFF & ~(0x3 << (2 * untagged_port))) | \
        (0x1 << (2 * untagged_port))


def vtu_data2(cpu_port):
    data = 0x0003
    data |= 0x0008 if cpu_port == CPU_PORT_B else 0x000C
    data |= 0x0020 if cpu_port == CPU_PORT_A else 0x0030
    return data


def port_setup(smi, port, pvid, mac_ctl=0):
    smi.update(port, REG_PORT_CTL0, 0xFFFF, CTL0_FORWARDING)
    smi.update(port, REG_PORT_CTL2, 0x0C00, CTL2_8021Q)
    smi.write(port, REG_PORT_VID, pvid)
    if mac_ctl:
        smi.write(port, REG_PORT_MAC, mac_ctl)


def cpu_port_setup(smi, port):
    sts = smi.read(port, REG_PORT_STS)
    smi.write(port, REG_PORT_STS, (sts & ~0x000F) | CMODE_1000BASE_X)
    time.sleep(0.02)
    port_setup(smi, port, 1, MAC_CTL_CPU)

    bmcr = smi.serdes_read(port, SERDES_BMCR)
    bmcr &= ~((1 << 15) | (1 << 14) | (1 << 11))
    bmcr |= (1 << 12) | (1 << 9)
    smi.serdes_write(port, SERDES_ADV, SERDES_ADV_VALUE)
    smi.serdes_write(port, SERDES_BMCR, bmcr)


def vlan_config(smi):
    for port in range(FIRST_PORT, LAST_PORT + 1):
        cpu = CPU_PORT_A if port <= PORTS_PER_UPLINK else CPU_PORT_B
        port_setup(smi, port, port)
        smi.vtu_load(port, port, vtu_data1(port), vtu_data2(cpu))
    cpu_port_setup(smi, CPU_PORT_A)
    cpu_port_setup(smi, CPU_PORT_B)


def led_config(smi):
    for port in range(FIRST_PORT, LAST_PORT + 1):
        smi.write(port, REG_PORT_LED, LED_VALUE)


def phy_setup(smi, speed=0):
    if speed == 1000:
        bmcr = BMCR_FULL_DUPLEX | BMCR_SPEED_1000
    elif speed == 100:
        bmcr = BMCR_FULL_DUPLEX | 0x2000
    elif speed == 10:
        bmcr = BMCR_FULL_DUPLEX
    else:
        bmcr = (BMCR_AN_ENABLE | BMCR_FULL_DUPLEX |
                BMCR_SPEED_1000 | BMCR_AN_RESTART)

    for port in range(FIRST_PORT, LAST_PORT + 1):
        smi.phy_write_page(port, 0xF8, 0x08, 0x0036)
        smi.phy_write_page(port, 0x00, 0x14, 0x8020)
        smi.phy_write(port, PHY_CTRL1000, PHY_ADV_1000FD)
        smi.phy_write(port, PHY_BMCR, bmcr)


def board_i2c(watchdog=True, sfp=True):
    bus = i2c_find_bus()
    fd = i2c_open(bus)
    log("i2c bus %d" % bus)
    try:
        if watchdog:
            try:
                smbus_write_byte_data(fd, I2C_PIC, 0x00, 0x00)
                try:
                    smbus_write_byte_data(fd, I2C_PIC2, 0x00, 0x00)
                except OSError:
                    pass
                log("PIC watchdog disarmed")
            except OSError as e:
                log("WARNING: watchdog not disarmed (%s)" % e)
        if sfp:
            for reg in CPLD_SFP:
                try:
                    val = smbus_read_byte_data(fd, I2C_CPLD, reg)
                except OSError as e:
                    log("WARNING: CPLD reg 0x%02x read failed (%s)" % (reg, e))
                    continue
                if not (val & CPLD_TX_DISABLE):
                    continue
                try:
                    smbus_write_byte_data(fd, I2C_CPLD, reg,
                                          val & ~CPLD_TX_DISABLE)
                    log("SFP reg 0x%02x TX_DISABLE cleared (0x%02x -> 0x%02x)"
                        % (reg, val, val & ~CPLD_TX_DISABLE))
                except OSError as e:
                    log("WARNING: CPLD reg 0x%02x write failed (%s)"
                        % (reg, e))
    finally:
        os.close(fd)


# --------------------------------------------------------------------------
# reporting


SPEED_NAMES = {3: "2.5G", 2: "1G", 1: "100M", 0: "10M"}


def show_info(smi):
    sid = switch_id(smi)
    print("switch id   0x%04x (%s)" % (sid,
          "Marvell 88E6190 rev %d" % (sid & 0xF)
          if (sid & 0xFFF0) == 0x1900 else "unexpected")) 
    print()
    print("port status mac_ctl ctl0   pvid ctl2   led    link speed")
    for port in range(0, 11):
        try:
            sts = smi.read(port, REG_PORT_STS)
            mac = smi.read(port, REG_PORT_MAC)
            ctl0 = smi.read(port, REG_PORT_CTL0)
            vid = smi.read(port, REG_PORT_VID)
            ctl2 = smi.read(port, REG_PORT_CTL2)
            led = smi.read(port, REG_PORT_LED)
        except Error:
            print("%-4d <read error>" % port)
            continue
        up = sts & (1 << 11)
        print("%-4d 0x%04x 0x%04x  0x%04x %-4d 0x%04x 0x%04x %-4s %s"
              % (port, sts, mac, ctl0, vid & 0x0FFF, ctl2, led,
                 "up" if up else "down",
                 SPEED_NAMES[(sts >> 8) & 3] if up else "-"))


def show_phy(smi):
    print("     id         bmcr bmsr anar lpar 1000c 1000s bmsr-link")
    for port in range(FIRST_PORT, LAST_PORT + 1):
        try:
            r02 = smi.phy_read(port, 0x02)
            r03 = smi.phy_read(port, 0x03)
            bmcr = smi.phy_read(port, PHY_BMCR)
            bmsr = smi.phy_read(port, PHY_BMSR)
            anar = smi.phy_read(port, 0x04)
            lpar = smi.phy_read(port, 0x05)
            t1kc = smi.phy_read(port, PHY_CTRL1000)
            t1ks = smi.phy_read(port, 0x0A)
        except Error:
            print("p%-3d <read error>" % port)
            continue
        print("p%-3d %04x:%04x %04x %04x %04x %04x %04x  %04x  %s"
              % (port, r02, r03, bmcr, bmsr, anar, lpar, t1kc, t1ks,
                 "yes" if bmsr & 0x0004 else "no"))


def diag(smi, port):
    """Same output as scripts/vep1400-linkdiag.sh, for userspace installs."""
    def has(val, bit):
        return bool(val & bit)

    def adv10(anar):
        out = []
        if has(anar, 0x0100):
            out.append("100FD")
        if has(anar, 0x0080):
            out.append("100HD")
        if has(anar, 0x0040):
            out.append("10FD")
        if has(anar, 0x0020):
            out.append("10HD")
        return " ".join(out)

    bmcr = smi.phy_read(port, PHY_BMCR)
    bmsr = smi.phy_read(port, PHY_BMSR)
    anar = smi.phy_read(port, 0x04)
    lpar = smi.phy_read(port, 0x05)
    t1kc = smi.phy_read(port, PHY_CTRL1000)
    t1ks = smi.phy_read(port, 0x0A)
    spec = smi.phy_read(port, 0x11)
    sts = smi.read(port, REG_PORT_STS)

    link = "up" if sts & (1 << 11) else "down"
    speed = SPEED_NAMES[(sts >> 8) & 3] if link == "up" else "-"
    duplex = ("full" if spec & 0x2000 else "half") if link == "up" else "-"

    local = adv10(anar)
    if has(t1kc, 0x0200):
        local += " 1000FD"
    if has(t1kc, 0x0100):
        local += " 1000HD"
    peer = adv10(lpar)

    print("port %d: link %s  speed=%s  duplex=%s  an=%s  an-complete=%s"
          % (port, link, speed, duplex,
             "on" if has(bmcr, 0x1000) else "off",
             "yes" if has(bmsr, 0x0020) else "no"))
    print("  local: anar=0x%04x 1000t-ctrl=0x%04x -> [%s]"
          % (anar, t1kc, local.strip() or "none"))
    print("  peer : anlpar=0x%04x (10/100), 1000t-status=0x%04x -> [%s]"
          % (lpar, t1ks, peer or "unknown"))

    if not has(t1kc, 0x0200):
        print("  note : this side does not advertise 1000BASE-T")
    if link == "up" and speed not in ("1G", "2.5G") and has(t1kc, 0x0200):
        print("  note : 1000BASE-T is advertised but the link came up at %s"
              " - check the cable and the peer port" % speed)
    if has(t1kc, 0x1000) or has(t1kc, 0x0800):
        print("  note : 1000BASE-T master/slave is forced (0x%04x), the driver"
              " programs 0x0200 (automatic)" % t1kc)


def watch_links(smi, seconds):
    prev = {}
    print("watching the front panel ports for %d s (Ctrl-C to stop)"
          % seconds)
    end = time.time() + seconds
    while time.time() < end:
        for port in range(FIRST_PORT, LAST_PORT + 1):
            try:
                bmsr = smi.phy_read(port, PHY_BMSR)
            except Error:
                continue
            up = bool(bmsr & 0x0004)
            if prev.get(port) != up:
                prev[port] = up
                speed = ""
                if up:
                    try:
                        sts = smi.read(port, REG_PORT_STS)
                        speed = " %s" % SPEED_NAMES[(sts >> 8) & 3]
                    except Error:
                        pass
                print("%s  GE%d %s%s"
                      % (time.strftime("%H:%M:%S"), port,
                         "link up" if up else "link down", speed))
                sys.stdout.flush()
        time.sleep(1)
    print("done")


# --------------------------------------------------------------------------


def log(msg):
    print("vep1400: %s" % msg)


def module_loaded():
    return os.path.isdir("/sys/module/vep1400")


def warn_if_module():
    if module_loaded():
        sys.stderr.write(
            "vep1400: note: vep1400.ko is loaded and polls the same SMI bus; "
            "readings may be unreliable.\n"
            "vep1400:       use /sys/kernel/debug/vep1400/{info,ports,phy} "
            "instead.\n")


def usage():
    print(__doc__.strip())
    sys.exit(0 if len(sys.argv) > 1 else 2)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help", "help"):
        usage()

    cmd = argv[1]
    args = argv[2:]
    if cmd not in ("info", "init", "reset", "phy", "diag", "watch"):
        die("unknown command %r (try --help)" % cmd)

    reset = "--reset" in args
    use_i2c = "--no-i2c" not in args

    if cmd in ("init", "reset") and module_loaded() and "--force" not in args:
        die("vep1400.ko is loaded and already owns the switch.\n"
            "       On Debian/Ubuntu/PVE use /sys/kernel/debug/vep1400/ and\n"
            "       the systemd services instead, or pass --force to override.")
    if cmd in ("info", "phy", "watch"):
        warn_if_module()

    smi = Smi()
    try:
        if cmd == "info":
            log("P2SB BAR 0x%x, pads at 0x%x" % (smi.bar, smi.padbar))
            show_info(smi)
            return 0

        if cmd == "phy":
            show_phy(smi)
            return 0

        if cmd == "watch":
            secs = 60
            for a in args:
                if a.isdigit():
                    secs = int(a)
            watch_links(smi, secs)
            return 0

        if cmd == "diag":
            port = 1
            for a in args:
                if a.isdigit():
                    port = int(a)
            if not FIRST_PORT <= port <= LAST_PORT:
                die("port must be 1..6")
            diag(smi, port)
            return 0

        if cmd == "reset":
            log("resetting the switch through the board reset pad")
            switch_reset(smi)
            log("done, the switch is back at its power-on defaults")
            return 0

        if use_i2c:
            try:
                board_i2c()
            except Error as e:
                log("WARNING: %s" % e)

        if reset:
            log("resetting the switch")
            switch_reset(smi)

        sid = switch_id(smi)
        if (sid & 0xFFF0) != 0x1900:
            die("unexpected switch id 0x%04x" % sid)
        log("Marvell 88E6190 rev %d" % (sid & 0xF))

        vlan_config(smi)
        log("GE1-GE3 -> VLAN 1-3 via CPU port %d, GE4-GE6 -> VLAN 4-6 "
            "via CPU port %d" % (CPU_PORT_A, CPU_PORT_B))
        led_config(smi)
        phy_setup(smi)
        log("front panel PHYs powered up, autonegotiation running")

        time.sleep(2)
        show_info(smi)
        return 0
    finally:
        smi.close()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Error as exc:
        die(str(exc))
    except KeyboardInterrupt:
        sys.exit(130)
