/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Dell VEP1400 / VMware SD-WAN Edge 610 - P2SB bit-banged SMI access.
 *
 * The 88E6190 SMI bus is not wired to any MDIO controller.  The Denverton
 * P2SB exposes the two SoC pads the board uses as MDC/MDIO, so this file
 * implements a small clause 22 master on top of them plus the register
 * helpers for the switch (VTU, SERDES, internal PHYs).
 */

#ifndef _VEP1400_MDIO_H
#define _VEP1400_MDIO_H

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/pci.h>
#include <linux/string.h>

/* P2SB (hidden by the Dell firmware, see vep1400_p2sb_scan()) */
#define VEP1400_P2SB_DEV_ID	0x19dd
#define VEP1400_NORTH_OFF	0x00c20000u
#define VEP1400_NORTH_LEN	0x10000u
#define VEP1400_P2SB_LEN	0x1000000u

/* P2SB pads used by the board as switch reset / MDC / MDIO */
#define VEP1400_PIN_SW_RESET	1
#define VEP1400_PIN_MDC		33
#define VEP1400_PIN_MDIO	34

#define PAD_CFG0_TXSTATE	BIT(0)
#define PAD_CFG0_RXSTATE	BIT(1)
#define PAD_CFG0_TXDIS		BIT(8)
#define PAD_CFG0_RXDIS		BIT(9)
#define PAD_CFG0_PMODE		GENMASK(12, 10)

#define VEP1400_SMI_DELAY_US	3

/* Marvell switch pseudo PHY addresses */
#define VEP1400_SMI_GLOBAL1	0x1b
#define VEP1400_SMI_GLOBAL2	0x1c

/* Per port registers */
#define VEP1400_REG_PORT_STS	0x00
#define VEP1400_REG_PORT_MAC	0x01
#define VEP1400_REG_SWITCH_ID	0x03
#define VEP1400_REG_PORT_CTL0	0x04
#define VEP1400_REG_PORT_VID	0x07
#define VEP1400_REG_PORT_CTL2	0x08
#define VEP1400_REG_PORT_LED	0x16

/* Global 1: VLAN table */
#define VEP1400_G1_VTU_FID	0x02
#define VEP1400_G1_VTU_OP	0x05
#define VEP1400_G1_VTU_VID	0x06
#define VEP1400_G1_VTU_DATA1	0x07
#define VEP1400_G1_VTU_DATA2	0x08
#define VEP1400_VTU_OP_BUSY	0x8000
#define VEP1400_VTU_OP_LOAD	0xb000
#define VEP1400_VTU_VID_VALID	0x1000

/* Global 2: indirect SERDES / PHY access */
#define VEP1400_G2_SMI_CMD	0x18
#define VEP1400_G2_SMI_DATA	0x19
#define VEP1400_G2_BUSY		0x8000
#define VEP1400_G2_C45_WRITE	0x0400
#define VEP1400_G2_C45_READ	0x0c00
#define VEP1400_G2_C22_MODE	0x1000
#define VEP1400_G2_C22_WRITE	0x0400
#define VEP1400_G2_C22_READ	0x0800
#define VEP1400_MMD_PHYXS	4

/* SERDES PCS registers (clause 45, MMD 4) */
#define VEP1400_SERDES_BMCR	0x2000
#define VEP1400_SERDES_BMSR	0x2001
#define VEP1400_SERDES_ADV	0x2004
#define VEP1400_SERDES_LPA	0x2005
#define VEP1400_SERDES_STS	0xa003

/* Front panel PHY registers */
#define VEP1400_PHY_BMCR	0x00
#define VEP1400_PHY_BMSR	0x01
#define VEP1400_PHY_CTRL1000	0x09
#define VEP1400_PHY_PAGE_REG	0x16
#define VEP1400_PHY_ADV_1000FD	0x0200
#define VEP1400_BMCR_AN_ENABLE	0x1000
#define VEP1400_BMCR_AN_RESTART	0x0200
#define VEP1400_BMCR_SPEED_1000	0x0040
#define VEP1400_BMCR_FULL_DUPLEX 0x0100

struct vep1400_bus {
	struct pci_dev *pdev;
	resource_size_t bar;
	void __iomem *north;
	void __iomem *pads;
};

/*
 * Some firmware revisions hide the P2SB PCI function while still reserving
 * its MMIO window.  The ACPI resource covers exactly P2SB_BAR + NORTH_OFF
 * and can sit anywhere below the PCI host bridge window, so walk the whole
 * resource tree.
 */
static inline resource_size_t vep1400_p2sb_scan(struct resource *r)
{
	resource_size_t bar;

	for (; r; r = r->sibling) {
		if (r->name && strstr(r->name, "INTC3000") &&
		    resource_size(r) == VEP1400_NORTH_LEN &&
		    ((r->start & (VEP1400_NORTH_LEN - 1)) ==
		     (VEP1400_NORTH_OFF & (VEP1400_NORTH_LEN - 1))) &&
		    !((r->start - VEP1400_NORTH_OFF) & (VEP1400_P2SB_LEN - 1)))
			return r->start - VEP1400_NORTH_OFF;

		bar = r->child ? vep1400_p2sb_scan(r->child) : 0;
		if (bar)
			return bar;
	}
	return 0;
}

static inline resource_size_t vep1400_p2sb_bar(struct pci_dev **pdev,
					       unsigned long override)
{
	resource_size_t bar;

	*pdev = pci_get_device(PCI_VENDOR_ID_INTEL, VEP1400_P2SB_DEV_ID, NULL);
	if (*pdev)
		return pci_resource_start(*pdev, 0);

	if (override)
		return override;

	bar = vep1400_p2sb_scan(iomem_resource.child);
	if (bar)
		pr_info("vep1400: P2SB hidden by firmware, BAR %pa from iomem\n",
			&bar);
	return bar;
}

static inline int vep1400_p2sb_map(struct vep1400_bus *bus,
				   unsigned long bar_override)
{
	resource_size_t bar;
	u32 reg0, padbar;

	memset(bus, 0, sizeof(*bus));

	bar = vep1400_p2sb_bar(&bus->pdev, bar_override);
	if (!bar) {
		pr_err("vep1400: P2SB BAR unavailable (pass p2sb_bar_addr=)\n");
		return -ENODEV;
	}
	bus->bar = bar;

	bus->north = ioremap(bar + VEP1400_NORTH_OFF, VEP1400_NORTH_LEN);
	if (!bus->north) {
		pci_dev_put(bus->pdev);
		bus->pdev = NULL;
		return -ENOMEM;
	}

	reg0 = readl(bus->north);
	padbar = readl(bus->north + 0x0c);
	pr_info("vep1400: P2SB %pa, north reg0=0x%08x padbar=0x%08x\n",
		&bar, reg0, padbar);
	if (reg0 == 0xffffffff || padbar >= VEP1400_NORTH_LEN) {
		pr_err("vep1400: P2SB north window not decodable\n");
		iounmap(bus->north);
		bus->north = NULL;
		pci_dev_put(bus->pdev);
		bus->pdev = NULL;
		return -ENODEV;
	}
	bus->pads = bus->north + padbar;
	return 0;
}

static inline void vep1400_p2sb_unmap(struct vep1400_bus *bus)
{
	if (bus->north)
		iounmap(bus->north);
	if (bus->pdev)
		pci_dev_put(bus->pdev);
	memset(bus, 0, sizeof(*bus));
}

static inline void vep1400_pad_input(struct vep1400_bus *bus, unsigned int pin)
{
	void __iomem *cfg = bus->pads + pin * 8;
	u32 v = readl(cfg);

	v &= ~PAD_CFG0_PMODE;
	v &= ~PAD_CFG0_RXDIS;
	v |= PAD_CFG0_TXDIS;
	writel(v, cfg);
	readl(cfg);
}

static inline void vep1400_pad_output(struct vep1400_bus *bus,
				      unsigned int pin, int high)
{
	void __iomem *cfg = bus->pads + pin * 8;
	u32 v = readl(cfg);

	v &= ~PAD_CFG0_PMODE;
	v &= ~(PAD_CFG0_TXDIS | PAD_CFG0_RXDIS | PAD_CFG0_TXSTATE);
	if (high)
		v |= PAD_CFG0_TXSTATE;
	writel(v, cfg);
	readl(cfg);
}

static inline int vep1400_pad_value(struct vep1400_bus *bus, unsigned int pin)
{
	return !!(readl(bus->pads + pin * 8) & PAD_CFG0_RXSTATE);
}

static inline void vep1400_mdc(struct vep1400_bus *bus, int high)
{
	vep1400_pad_output(bus, VEP1400_PIN_MDC, high);
	udelay(VEP1400_SMI_DELAY_US);
}

static inline void vep1400_mdio_drive(struct vep1400_bus *bus, int high)
{
	if (high)
		vep1400_pad_input(bus, VEP1400_PIN_MDIO);
	else
		vep1400_pad_output(bus, VEP1400_PIN_MDIO, 0);
	udelay(VEP1400_SMI_DELAY_US);
}

static inline void vep1400_mdio_bit(struct vep1400_bus *bus, int bit)
{
	vep1400_mdc(bus, 0);
	vep1400_mdio_drive(bus, bit);
	vep1400_mdc(bus, 1);
}

/* Sample the pad after the rising MDC edge; this board returns the data one
 * clock early, so the caller shifts the result down by one bit.
 */
static inline int vep1400_mdio_sample(struct vep1400_bus *bus)
{
	vep1400_mdc(bus, 0);
	vep1400_mdio_drive(bus, 1);
	vep1400_mdc(bus, 1);
	return vep1400_pad_value(bus, VEP1400_PIN_MDIO);
}

static inline void vep1400_mdio_header(struct vep1400_bus *bus, u8 phy,
				       u8 reg, bool write)
{
	int i;

	for (i = 0; i < 32; i++)
		vep1400_mdio_bit(bus, 1);
	vep1400_mdio_bit(bus, 0);
	vep1400_mdio_bit(bus, 1);
	vep1400_mdio_bit(bus, write ? 0 : 1);
	vep1400_mdio_bit(bus, write ? 1 : 0);
	for (i = 4; i >= 0; i--)
		vep1400_mdio_bit(bus, (phy >> i) & 1);
	for (i = 4; i >= 0; i--)
		vep1400_mdio_bit(bus, (reg >> i) & 1);
}

static inline int vep1400_smi_read(struct vep1400_bus *bus, u8 phy, u8 reg,
				   u16 *value)
{
	u16 raw = 0;
	int i;

	vep1400_mdio_header(bus, phy, reg, false);
	(void)vep1400_mdio_sample(bus);		/* turnaround */
	(void)vep1400_mdio_sample(bus);		/* ack (not reliable here) */
	for (i = 15; i >= 0; i--)
		raw |= vep1400_mdio_sample(bus) << i;
	vep1400_mdc(bus, 0);
	vep1400_mdio_drive(bus, 1);

	*value = raw >> 1;
	return 0;
}

static inline void vep1400_smi_write(struct vep1400_bus *bus, u8 phy, u8 reg,
				     u16 value)
{
	int i;

	vep1400_mdio_header(bus, phy, reg, true);
	vep1400_mdio_bit(bus, 1);
	vep1400_mdio_bit(bus, 0);
	for (i = 15; i >= 0; i--)
		vep1400_mdio_bit(bus, (value >> i) & 1);
	vep1400_mdc(bus, 0);
	vep1400_mdio_drive(bus, 1);
}

static inline int vep1400_smi_update(struct vep1400_bus *bus, int port,
				     int reg, u16 clear, u16 set, u16 *out)
{
	u16 v;
	int err;

	err = vep1400_smi_read(bus, port, reg, &v);
	if (err)
		return err;
	v = (v & ~clear) | set;
	vep1400_smi_write(bus, port, reg, v);
	if (out)
		*out = v;
	return 0;
}

static inline int vep1400_wait_idle(struct vep1400_bus *bus, u8 phy, u8 reg,
				    u16 mask, int retries)
{
	u16 v;
	int i;

	for (i = 0; i < retries; i++) {
		if (vep1400_smi_read(bus, phy, reg, &v))
			return -EIO;
		if (!(v & mask))
			return 0;
		udelay(100);
	}
	return -ETIMEDOUT;
}

static inline int vep1400_vtu_load(struct vep1400_bus *bus, u16 vid, u16 fid,
				   u16 data1, u16 data2)
{
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL1, VEP1400_G1_VTU_FID, fid);
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL1, VEP1400_G1_VTU_VID,
			  VEP1400_VTU_VID_VALID | vid);
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL1, VEP1400_G1_VTU_DATA1, data1);
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL1, VEP1400_G1_VTU_DATA2, data2);
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL1, VEP1400_G1_VTU_OP,
			  VEP1400_VTU_OP_LOAD);
	return vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL1, VEP1400_G1_VTU_OP,
				 VEP1400_VTU_OP_BUSY, 100);
}

static inline int vep1400_g2_addr(struct vep1400_bus *bus, u16 port, u16 reg)
{
	int err;

	err = vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				VEP1400_G2_BUSY, 100);
	if (err)
		return err;
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_DATA, reg);
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
			  VEP1400_G2_BUSY | (port << 5) | VEP1400_MMD_PHYXS);
	return vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				 VEP1400_G2_BUSY, 100);
}

static inline int vep1400_serdes_read(struct vep1400_bus *bus, u16 port,
				      u16 reg, u16 *value)
{
	int err = vep1400_g2_addr(bus, port, reg);

	if (err)
		return err;
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
			  VEP1400_G2_BUSY | VEP1400_G2_C45_READ | (port << 5) |
			  VEP1400_MMD_PHYXS);
	err = vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				VEP1400_G2_BUSY, 100);
	if (err)
		return err;
	return vep1400_smi_read(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_DATA,
				value);
}

static inline int vep1400_serdes_write(struct vep1400_bus *bus, u16 port,
				       u16 reg, u16 value)
{
	int err = vep1400_g2_addr(bus, port, reg);

	if (err)
		return err;
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_DATA, value);
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
			  VEP1400_G2_BUSY | VEP1400_G2_C45_WRITE | (port << 5) |
			  VEP1400_MMD_PHYXS);
	return vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				 VEP1400_G2_BUSY, 100);
}

/* Indirect clause 22 access to the switch internal PHYs */
static inline int vep1400_phy_read(struct vep1400_bus *bus, int port, int reg,
				   u16 *value)
{
	u16 cmd = VEP1400_G2_BUSY | VEP1400_G2_C22_MODE |
		  VEP1400_G2_C22_READ | ((port & 0x1f) << 5) | (reg & 0x1f);
	int err;

	err = vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				VEP1400_G2_BUSY, 100);
	if (err)
		return err;
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD, cmd);
	err = vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				VEP1400_G2_BUSY, 100);
	if (err)
		return err;
	return vep1400_smi_read(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_DATA,
				value);
}

static inline int vep1400_phy_write(struct vep1400_bus *bus, int port,
				    int reg, u16 value)
{
	u16 cmd = VEP1400_G2_BUSY | VEP1400_G2_C22_MODE |
		  VEP1400_G2_C22_WRITE | ((port & 0x1f) << 5) | (reg & 0x1f);
	int err;

	err = vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				VEP1400_G2_BUSY, 100);
	if (err)
		return err;
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_DATA, value);
	vep1400_smi_write(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD, cmd);
	return vep1400_wait_idle(bus, VEP1400_SMI_GLOBAL2, VEP1400_G2_SMI_CMD,
				 VEP1400_G2_BUSY, 100);
}

static inline int vep1400_phy_write_page(struct vep1400_bus *bus, int port,
					 u16 page, int reg, u16 value)
{
	int err = vep1400_phy_write(bus, port, VEP1400_PHY_PAGE_REG, page);

	if (err)
		return err;
	return vep1400_phy_write(bus, port, reg, value);
}

#endif /* _VEP1400_MDIO_H */
