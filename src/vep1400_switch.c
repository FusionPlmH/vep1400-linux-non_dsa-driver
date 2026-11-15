// SPDX-License-Identifier: GPL-2.0
/*
 * Dell VEP1400 / VMware SD-WAN Edge 610 - Marvell 88E6190 switch support.
 *
 * The six front panel RJ45 ports are connected to a Marvell 88E6190 that is
 * wired to two Intel X553 uplinks.  Debian, Ubuntu, Proxmox VE and VyOS all
 * ship a kernel without CONFIG_NET_DSA, so the switch is programmed the same
 * way Dell's DiagOS does it - one VLAN per front panel port:
 *
 *   front panel 1..3 <-> CPU port 10 <-> 0000:03:00.0 (VLAN 1..3)
 *   front panel 4..6 <-> CPU port  9 <-> 0000:03:00.1 (VLAN 4..6)
 *
 * Each front panel port is a secure 802.1Q access port, the CPU links carry
 * the tags.  Userspace creates GE1..GE6 on top of the uplinks.
 *
 * The front panel PHYs are powered up once and then left to plain
 * autonegotiation: a plugged cable links at its highest common speed within
 * a few seconds, exactly like a normal NIC.
 */

#include <linux/debugfs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/seq_file.h>
#include <linux/workqueue.h>

#include "vep1400.h"
#include "vep1400_mdio.h"

#define DRV "vep1400"

/* Front panel ports 1..6, CPU ports 9 and 10 */
#define VEP1400_FIRST_PORT	1
#define VEP1400_LAST_PORT	6
#define VEP1400_CPU_PORT_A	10	/* wired to 0000:03:00.0 */
#define VEP1400_CPU_PORT_B	9	/* wired to 0000:03:00.1 */

#define VEP1400_MAC_CTL_CPU	0x203e	/* IPG 13, forced 1G full duplex */
#define VEP1400_CTL0_FORWARDING	0x007f
#define VEP1400_CTL2_8021Q	0x2c80
#define VEP1400_LED_VALUE	0x8030
#define VEP1400_SERDES_ADV_VALUE 0x00e0	/* 1G full duplex capable */
#define VEP1400_CMODE_1000BASE_X 0x09

#define VEP1400_POLL_MS		3000
#define VEP1400_SERDES_WAIT_MS	1500

enum vep1400_strap_state {
	VEP1400_STRAP_SKIPPED,
	VEP1400_STRAP_APPLIED,
	VEP1400_STRAP_BUSY,
	VEP1400_STRAP_ABSENT,
};

static const char * const vep1400_strap_names[] = {
	"skipped", "applied", "busy", "absent"
};

static unsigned long p2sb_bar_addr;
module_param(p2sb_bar_addr, ulong, 0444);
MODULE_PARM_DESC(p2sb_bar_addr,
		 "P2SB MMIO BAR when the PCI function is hidden by the firmware (0 = autodetect)");

static unsigned int x553_speed = 1000;
module_param(x553_speed, uint, 0444);
MODULE_PARM_DESC(x553_speed,
		 "X553 backplane speed strap in Mbps (1000 or 2500); 0 keeps the NVM value. Applied at load time, so it must run before ixgbe probes");

static unsigned int phy_speed;
module_param(phy_speed, uint, 0444);
MODULE_PARM_DESC(phy_speed,
		 "Force the front panel speed instead of autonegotiation: 0 = autoneg (default), 10, 100 or 1000");

static bool led_init = true;
module_param(led_init, bool, 0444);
MODULE_PARM_DESC(led_init, "Program the front panel LED control registers");

static struct vep1400_bus bus;
static struct dentry *debugfs_root;
static DEFINE_MUTEX(smi_lock);	/* serialises SMI users (debugfs vs. work) */
static struct delayed_work link_work;
static bool link_work_on;
static bool link_up[VEP1400_LAST_PORT + 1];
static u16 link_speed[VEP1400_LAST_PORT + 1];
static u16 switch_id;
static int strap_state = VEP1400_STRAP_SKIPPED;

/* --------------------------------------------------------------------- */
/* switch configuration							*/

static const char *vep1400_speed_name(u16 status)
{
	switch ((status >> 8) & 0x3) {
	case 3:
		return "2.5G";
	case 2:
		return "1G";
	case 1:
		return "100M";
	default:
		return "10M";
	}
}

static int vep1400_port_setup(int port, u16 pvid, u16 mac_ctl)
{
	int err;

	err = vep1400_smi_update(&bus, port, VEP1400_REG_PORT_CTL0, 0xffff,
				 VEP1400_CTL0_FORWARDING, NULL);
	if (err)
		return err;
	err = vep1400_smi_update(&bus, port, VEP1400_REG_PORT_CTL2, 0x0c00,
				 VEP1400_CTL2_8021Q, NULL);
	if (err)
		return err;
	vep1400_smi_write(&bus, port, VEP1400_REG_PORT_VID, pvid);
	if (mac_ctl)
		vep1400_smi_write(&bus, port, VEP1400_REG_PORT_MAC, mac_ctl);
	return 0;
}

/* Two bits per port: 01 = untagged member, 10 = tagged member,
 * 11 = not a member.
 */
static u16 vep1400_vtu_data1(int untagged_port)
{
	return (0xffff & ~(0x3 << (2 * untagged_port))) |
	       (0x1 << (2 * untagged_port));
}

static u16 vep1400_vtu_data2(int cpu_port)
{
	u16 data = 0x0003;		/* port 8 stays out of the VLAN */

	data |= (cpu_port == VEP1400_CPU_PORT_B) ? 0x0008 : 0x000c;
	data |= (cpu_port == VEP1400_CPU_PORT_A) ? 0x0020 : 0x0030;
	return data;
}

static int vep1400_cpu_port_setup(int port)
{
	u16 sts = 0, bmcr = 0;
	int err;

	/* The PCS mode is the writable low nibble of the port status
	 * register and must be set before the SERDES is configured,
	 * otherwise both sides negotiate different Ethernet modes.
	 */
	err = vep1400_smi_read(&bus, port, VEP1400_REG_PORT_STS, &sts);
	if (err)
		return err;
	vep1400_smi_write(&bus, port, VEP1400_REG_PORT_STS,
			  (sts & ~0x000f) | VEP1400_CMODE_1000BASE_X);
	msleep(20);

	err = vep1400_port_setup(port, 1, VEP1400_MAC_CTL_CPU);
	if (err)
		return err;

	/* Power up the SERDES PCS and restart in-band autonegotiation */
	err = vep1400_serdes_read(&bus, port, VEP1400_SERDES_BMCR, &bmcr);
	if (err)
		return err;
	bmcr &= ~(BIT(15) | BIT(14) | BIT(11));
	bmcr |= BIT(12) | BIT(9);
	vep1400_serdes_write(&bus, port, VEP1400_SERDES_ADV,
			     VEP1400_SERDES_ADV_VALUE);
	vep1400_serdes_write(&bus, port, VEP1400_SERDES_BMCR, bmcr);
	return 0;
}

static int vep1400_vlan_config(void)
{
	int port, err, cpu_port;
	u16 sts = 0;
	unsigned long deadline;

	for (port = VEP1400_FIRST_PORT; port <= VEP1400_LAST_PORT; port++) {
		cpu_port = port <= 3 ? VEP1400_CPU_PORT_A : VEP1400_CPU_PORT_B;

		err = vep1400_port_setup(port, port, 0);
		if (err)
			return err;
		err = vep1400_vtu_load(&bus, port, port,
				       vep1400_vtu_data1(port),
				       vep1400_vtu_data2(cpu_port));
		if (err)
			return err;
		pr_info(DRV ": GE%d -> VLAN %d via CPU port %d\n", port, port,
			cpu_port);
	}

	err = vep1400_cpu_port_setup(VEP1400_CPU_PORT_A);
	if (err)
		return err;
	err = vep1400_cpu_port_setup(VEP1400_CPU_PORT_B);
	if (err)
		return err;

	/* Wait for both uplinks once so a broken strap shows up in the log */
	deadline = jiffies + msecs_to_jiffies(VEP1400_SERDES_WAIT_MS);
	do {
		u16 a = 0, b = 0;

		vep1400_smi_read(&bus, VEP1400_CPU_PORT_A, VEP1400_REG_PORT_STS,
				 &a);
		vep1400_smi_read(&bus, VEP1400_CPU_PORT_B, VEP1400_REG_PORT_STS,
				 &b);
		if ((a & BIT(11)) && (b & BIT(11)))
			break;
		msleep(50);
	} while (time_before(jiffies, deadline));

	vep1400_smi_read(&bus, VEP1400_CPU_PORT_A, VEP1400_REG_PORT_STS, &sts);
	pr_info(DRV ": CPU port %d %s\n", VEP1400_CPU_PORT_A,
		(sts & BIT(11)) ? vep1400_speed_name(sts) : "not linked");
	vep1400_smi_read(&bus, VEP1400_CPU_PORT_B, VEP1400_REG_PORT_STS, &sts);
	pr_info(DRV ": CPU port %d %s\n", VEP1400_CPU_PORT_B,
		(sts & BIT(11)) ? vep1400_speed_name(sts) : "not linked");
	return 0;
}

/* --------------------------------------------------------------------- */
/* X553 backplane strap							*/

static int vep1400_x553_strap(unsigned int fn)
{
	struct pci_dev *dev;
	void __iomem *bar;
	u32 old, new;

	dev = pci_get_domain_bus_and_slot(0, 3, PCI_DEVFN(0, fn));
	if (!dev || dev->device != 0x15c3) {
		pci_dev_put(dev);
		return -ENODEV;
	}
	if (dev->dev.driver) {
		pr_warn(DRV ": 0000:03:00.%u is bound to %s, strap not applied\n",
			fn, dev->dev.driver->name);
		pci_dev_put(dev);
		return -EBUSY;
	}

	bar = pci_iomap(dev, 0, 0);
	if (!bar) {
		pci_dev_put(dev);
		return -ENOMEM;
	}
	old = readl(bar + 0x11178);			/* NW_MNG_IF_SEL */
	new = (old & ~GENMASK(21, 17)) |
	      (x553_speed == 2500 ? BIT(20) : BIT(19)) | BIT(25);
	writel(new, bar + 0x11178);
	readl(bar + 0x11178);
	pci_iounmap(dev, bar);
	pci_dev_put(dev);

	pr_info(DRV ": X553 fn%u NW_MNG_IF_SEL 0x%08x -> 0x%08x (%uM)\n", fn,
		old, new, x553_speed);
	return 0;
}

/* --------------------------------------------------------------------- */
/* front panel PHYs							*/

/* Power up the PHY once, advertise 10/100/1000 and start autonegotiation.
 * After this the PHY is left alone: cable insertion is handled by its own
 * autonegotiation state machine.
 */
static void vep1400_phy_setup(void)
{
	u16 bmcr;
	int port;

	if (phy_speed == 1000)
		bmcr = VEP1400_BMCR_FULL_DUPLEX | VEP1400_BMCR_SPEED_1000;
	else if (phy_speed == 100)
		bmcr = VEP1400_BMCR_FULL_DUPLEX | 0x2000;
	else if (phy_speed == 10)
		bmcr = VEP1400_BMCR_FULL_DUPLEX;
	else
		bmcr = VEP1400_BMCR_AN_ENABLE | VEP1400_BMCR_FULL_DUPLEX |
		       VEP1400_BMCR_SPEED_1000 | VEP1400_BMCR_AN_RESTART;

	for (port = VEP1400_FIRST_PORT; port <= VEP1400_LAST_PORT; port++) {
		/* DiagOS PHY init sequence */
		vep1400_phy_write_page(&bus, port, 0xf8, 0x08, 0x0036);
		vep1400_phy_write_page(&bus, port, 0x00, 0x14, 0x8020);

		/* The board straps 1000BASE-T control to 0x0e00 (manual
		 * master *and* manual slave, an invalid combination that
		 * stalls autonegotiation); use automatic master/slave.
		 */
		vep1400_phy_write(&bus, port, VEP1400_PHY_CTRL1000,
				  VEP1400_PHY_ADV_1000FD);
		vep1400_phy_write(&bus, port, VEP1400_PHY_BMCR, bmcr);
	}
}

static void vep1400_led_config(void)
{
	int port;

	for (port = VEP1400_FIRST_PORT; port <= VEP1400_LAST_PORT; port++)
		vep1400_smi_write(&bus, port, VEP1400_REG_PORT_LED,
				  VEP1400_LED_VALUE);
}

/* --------------------------------------------------------------------- */
/* read-only link monitor						*/

/* The PHY knows whether the cable is live; the switch port status only tells
 * us the negotiated speed.  This work never writes to the PHY, so it cannot
 * disturb a running autonegotiation.
 */
static void vep1400_link_poll(struct work_struct *work)
{
	int port;

	mutex_lock(&smi_lock);
	for (port = VEP1400_FIRST_PORT; port <= VEP1400_LAST_PORT; port++) {
		u16 bmsr = 0, sts = 0;

		if (vep1400_phy_read(&bus, port, VEP1400_PHY_BMSR, &bmsr))
			continue;

		if (!(bmsr & BIT(2))) {
			if (link_up[port]) {
				link_up[port] = false;
				pr_info(DRV ": GE%d link down\n", port);
			}
			continue;
		}

		if (vep1400_smi_read(&bus, port, VEP1400_REG_PORT_STS, &sts))
			continue;
		if (link_up[port] && sts == link_speed[port])
			continue;

		link_up[port] = true;
		link_speed[port] = sts;
		pr_info(DRV ": GE%d link up (%s)\n", port,
			vep1400_speed_name(sts));
	}
	mutex_unlock(&smi_lock);

	schedule_delayed_work(&link_work, msecs_to_jiffies(VEP1400_POLL_MS));
}

/* --------------------------------------------------------------------- */
/* debugfs								*/

static int vep1400_info_show(struct seq_file *s, void *unused)
{
	u16 sts_a = 0, sts_b = 0;

	mutex_lock(&smi_lock);
	vep1400_smi_read(&bus, VEP1400_CPU_PORT_A, VEP1400_REG_PORT_STS, &sts_a);
	vep1400_smi_read(&bus, VEP1400_CPU_PORT_B, VEP1400_REG_PORT_STS, &sts_b);
	mutex_unlock(&smi_lock);

	seq_printf(s, "switch_id    0x%04x (88E6190 rev %u)\n", switch_id,
		   switch_id & 0xf);
	seq_printf(s, "x553_speed   %u\n", x553_speed);
	seq_printf(s, "x553_strap   %s\n", vep1400_strap_names[strap_state]);
	seq_printf(s, "phy_speed    %u\n", phy_speed);
	seq_printf(s, "led_init     %u\n", led_init ? 1 : 0);
	seq_printf(s, "cpu_port_%d   %s\n", VEP1400_CPU_PORT_A,
		   (sts_a & BIT(11)) ? "up" : "down");
	seq_printf(s, "cpu_port_%d   %s\n", VEP1400_CPU_PORT_B,
		   (sts_b & BIT(11)) ? "up" : "down");
	return 0;
}

static int vep1400_info_open(struct inode *inode, struct file *file)
{
	return single_open(file, vep1400_info_show, NULL);
}

static const struct file_operations vep1400_info_fops = {
	.owner = THIS_MODULE,
	.open = vep1400_info_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static int vep1400_ports_show(struct seq_file *s, void *unused)
{
	int port;

	seq_puts(s, "port status mac_ctl ctl0 pvid ctl2 led link\n");
	mutex_lock(&smi_lock);
	for (port = 0; port <= 10; port++) {
		u16 sts, mac, ctl0, vid, ctl2, led;

		if (vep1400_smi_read(&bus, port, VEP1400_REG_PORT_STS, &sts) ||
		    vep1400_smi_read(&bus, port, VEP1400_REG_PORT_MAC, &mac) ||
		    vep1400_smi_read(&bus, port, VEP1400_REG_PORT_CTL0, &ctl0) ||
		    vep1400_smi_read(&bus, port, VEP1400_REG_PORT_VID, &vid) ||
		    vep1400_smi_read(&bus, port, VEP1400_REG_PORT_CTL2, &ctl2) ||
		    vep1400_smi_read(&bus, port, VEP1400_REG_PORT_LED, &led)) {
			seq_printf(s, "%-4d <read error>\n", port);
			continue;
		}
		seq_printf(s, "%-4d 0x%04x 0x%04x 0x%04x %-4u 0x%04x 0x%04x %s\n",
			   port, sts, mac, ctl0, vid & 0x0fff, ctl2, led,
			   (sts & BIT(11)) ? "up" : "down");
	}
	mutex_unlock(&smi_lock);
	return 0;
}

static int vep1400_ports_open(struct inode *inode, struct file *file)
{
	return single_open(file, vep1400_ports_show, NULL);
}

static const struct file_operations vep1400_ports_fops = {
	.owner = THIS_MODULE,
	.open = vep1400_ports_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static int vep1400_phy_show(struct seq_file *s, void *unused)
{
	static const int regs[] = { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x09,
				    0x0a, 0x10, 0x11, 0x14, 0x16, 0x1b };
	int port, i;

	for (port = VEP1400_FIRST_PORT; port <= VEP1400_LAST_PORT; port++) {
		seq_printf(s, "p%d", port);
		mutex_lock(&smi_lock);
		for (i = 0; i < ARRAY_SIZE(regs); i++) {
			u16 v = 0;

			if (vep1400_phy_read(&bus, port, regs[i], &v))
				seq_printf(s, " r%02x=err", regs[i]);
			else
				seq_printf(s, " r%02x=%04x", regs[i], v);
		}
		mutex_unlock(&smi_lock);
		seq_putc(s, '\n');
	}
	return 0;
}

static int vep1400_phy_open(struct inode *inode, struct file *file)
{
	return single_open(file, vep1400_phy_show, NULL);
}

static const struct file_operations vep1400_phy_fops = {
	.owner = THIS_MODULE,
	.open = vep1400_phy_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

/* Root-only bring-up helper: echo "<port> <reg> <value>" (reg and value in
 * hex) writes one front panel PHY register and logs the previous value.
 */
static ssize_t vep1400_phy_write_store(struct file *file,
				       const char __user *user_buf,
				       size_t count, loff_t *ppos)
{
	char buf[64];
	unsigned int port, reg, val;
	u16 old = 0;
	int n, err;

	if (count >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, user_buf, count))
		return -EFAULT;
	buf[count] = '\0';

	n = sscanf(buf, "%u %x %x", &port, &reg, &val);
	if (n != 3 || port < VEP1400_FIRST_PORT || port > VEP1400_LAST_PORT ||
	    reg > 0x1f || val > 0xffff)
		return -EINVAL;

	mutex_lock(&smi_lock);
	err = vep1400_phy_read(&bus, port, reg, &old);
	if (!err)
		err = vep1400_phy_write(&bus, port, reg, val);
	mutex_unlock(&smi_lock);
	if (err)
		return err;

	pr_info(DRV ": debugfs GE%u r%02x 0x%04x -> 0x%04x\n", port, reg, old,
		(u16)val);
	return count;
}

static const struct file_operations vep1400_phy_write_fops = {
	.owner = THIS_MODULE,
	.write = vep1400_phy_write_store,
	.llseek = noop_llseek,
};

/* --------------------------------------------------------------------- */
/* module init/exit							*/

static int __init vep1400_switch_init(void)
{
	int err, fn;

	err = vep1400_p2sb_map(&bus, p2sb_bar_addr);
	if (err)
		return err;

	/* Reset the switch through the board's reset pad */
	vep1400_pad_output(&bus, VEP1400_PIN_MDC, 0);
	vep1400_pad_input(&bus, VEP1400_PIN_MDIO);
	vep1400_pad_output(&bus, VEP1400_PIN_SW_RESET, 0);
	msleep(100);
	vep1400_pad_output(&bus, VEP1400_PIN_SW_RESET, 1);
	msleep(500);

	vep1400_smi_read(&bus, 0, VEP1400_REG_SWITCH_ID, &switch_id);
	if ((switch_id & 0xfff0) != 0x1900) {
		pr_err(DRV ": unexpected switch id 0x%04x\n", switch_id);
		err = -ENODEV;
		goto err_unmap;
	}
	pr_info(DRV ": Marvell 88E6190 rev %u\n", switch_id & 0xf);

	if (x553_speed == 1000 || x553_speed == 2500) {
		strap_state = VEP1400_STRAP_APPLIED;
		for (fn = 0; fn < 2; fn++) {
			err = vep1400_x553_strap(fn);
			if (err == -EBUSY)
				strap_state = VEP1400_STRAP_BUSY;
			else if (err && strap_state != VEP1400_STRAP_BUSY)
				strap_state = VEP1400_STRAP_ABSENT;
		}
		if (strap_state == VEP1400_STRAP_BUSY)
			pr_warn(DRV ": ixgbe already owns the uplinks, reload it to apply the 1G strap\n");
	}

	err = vep1400_vlan_config();
	if (err)
		goto err_unmap;

	if (led_init)
		vep1400_led_config();

	vep1400_phy_setup();
	pr_info(DRV ": front panel PHYs powered up%s\n",
		phy_speed ? ", speed forced" : ", autonegotiation running");

	INIT_DELAYED_WORK(&link_work, vep1400_link_poll);
	schedule_delayed_work(&link_work, msecs_to_jiffies(VEP1400_POLL_MS));
	link_work_on = true;

	debugfs_root = debugfs_create_dir("vep1400", NULL);
	if (!IS_ERR_OR_NULL(debugfs_root)) {
		debugfs_create_file("info", 0444, debugfs_root, NULL,
				    &vep1400_info_fops);
		debugfs_create_file("ports", 0444, debugfs_root, NULL,
				    &vep1400_ports_fops);
		debugfs_create_file("phy", 0444, debugfs_root, NULL,
				    &vep1400_phy_fops);
		debugfs_create_file("phy_write", 0200, debugfs_root, NULL,
				    &vep1400_phy_write_fops);
	}
	pr_info(DRV ": switch ready\n");
	return 0;

err_unmap:
	vep1400_p2sb_unmap(&bus);
	return err;
}

static void __exit vep1400_switch_exit(void)
{
	if (link_work_on) {
		cancel_delayed_work_sync(&link_work);
		link_work_on = false;
	}
	debugfs_remove_recursive(debugfs_root);
	debugfs_root = NULL;

	if (bus.pads) {
		int port;

		mutex_lock(&smi_lock);
		for (port = VEP1400_FIRST_PORT; port <= VEP1400_LAST_PORT; port++)
			vep1400_smi_update(&bus, port, VEP1400_REG_PORT_CTL0,
					   0x0003, 0, NULL);
		mutex_unlock(&smi_lock);
	}
	vep1400_p2sb_unmap(&bus);
	pr_info(DRV ": switch unloaded\n");
}

static int __init vep1400_init(void)
{
	int err;

	/* Board I2C first: the PIC watchdog reboots the box after 4-5
	 * minutes until it is disarmed.
	 */
	vep1400_board_init();

	err = vep1400_switch_init();
	if (err)
		vep1400_board_exit();
	return err;
}

static void __exit vep1400_exit(void)
{
	vep1400_switch_exit();
	vep1400_board_exit();
}

module_init(vep1400_init);
module_exit(vep1400_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("VEP1400 Linux port");
MODULE_DESCRIPTION("Dell VEP1400 / VMware Edge 610 board support (88E6190 switch, front panel PHYs, LEDs, watchdog, SFP TX)");
MODULE_SOFTDEP("pre: i2c_ismt");
