// SPDX-License-Identifier: GPL-2.0
/*
 * Dell VEP1400 / VMware SD-WAN Edge 610 - board I2C setup.
 *
 * Replaces the two i2cset lines of DiagOS' rc.local:
 *   - disarm the PIC hardware watchdog (SMBus 0x22 / 0x24); without this
 *     the board reboots every 4-5 minutes
 *   - clear TX_DISABLE on both SFP cages (board CPLD 0x31, reg 0x10/0x11)
 *
 * DiagOS hardcodes i2c bus 1; on a stock Debian/Ubuntu/PVE/VyOS install the
 * iSMT adapter can be any number, so it is located by name.
 *
 * There is no fan on this board (it is passively cooled), and the temperature
 * is read from the CPU's coretemp MSR, so nothing else needs programming.
 */

#include <linux/i2c.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/string.h>

#include "vep1400.h"

#define DRV "vep1400"

#define VEP1400_I2C_PIC		0x22	/* PIC watchdog */
#define VEP1400_I2C_PIC2	0x24	/* PIC watchdog counter */
#define VEP1400_I2C_CPLD	0x31	/* board CPLD */
#define VEP1400_CPLD_SFP0	0x10
#define VEP1400_CPLD_SFP1	0x11
#define VEP1400_CPLD_TX_DISABLE	0x80

static int bus_num = -1;
module_param(bus_num, int, 0444);
MODULE_PARM_DESC(bus_num, "iSMT i2c bus number (-1 = find the adapter by name)");

static bool watchdog = true;
module_param(watchdog, bool, 0644);
MODULE_PARM_DESC(watchdog, "Disarm the PIC hardware watchdog");

static bool sfp_tx = true;
module_param(sfp_tx, bool, 0644);
MODULE_PARM_DESC(sfp_tx, "Clear TX_DISABLE on both SFP cages");

static struct i2c_adapter *adapter;
static struct i2c_client *client_pic, *client_pic2, *client_cpld;

static struct i2c_adapter *vep1400_find_adapter(void)
{
	struct i2c_adapter *a;
	int i;

	if (bus_num >= 0)
		return i2c_get_adapter(bus_num);

	for (i = 0; i < 256; i++) {
		a = i2c_get_adapter(i);
		if (!a)
			continue;
		if (strstr(a->name, "iSMT") || strstr(a->name, "ismt"))
			return a;
		i2c_put_adapter(a);
	}
	return NULL;
}

static struct i2c_client *vep1400_client(u16 addr)
{
	struct i2c_client *client = i2c_new_dummy_device(adapter, addr);

	if (IS_ERR(client)) {
		pr_warn(DRV ": no i2c device at 0x%02x (%ld)\n", addr,
			PTR_ERR(client));
		return NULL;
	}
	return client;
}

static void vep1400_watchdog_off(void)
{
	int err;

	if (!client_pic)
		return;

	err = i2c_smbus_write_byte_data(client_pic, 0x00, 0x00);
	if (err) {
		pr_err(DRV ": PIC watchdog not disarmed (%d)\n", err);
		return;
	}
	pr_info(DRV ": PIC watchdog disarmed\n");

	if (client_pic2)
		i2c_smbus_write_byte_data(client_pic2, 0x00, 0x00);
}

static void vep1400_sfp_tx_on(void)
{
	int reg, val;

	if (!client_cpld)
		return;

	for (reg = VEP1400_CPLD_SFP0; reg <= VEP1400_CPLD_SFP1; reg++) {
		val = i2c_smbus_read_byte_data(client_cpld, reg);
		if (val < 0) {
			pr_warn(DRV ": CPLD reg 0x%02x read failed (%d)\n", reg,
				val);
			continue;
		}
		if (!(val & VEP1400_CPLD_TX_DISABLE))
			continue;
		if (i2c_smbus_write_byte_data(client_cpld, reg,
					      val & ~VEP1400_CPLD_TX_DISABLE)) {
			pr_warn(DRV ": CPLD reg 0x%02x write failed\n", reg);
			continue;
		}
		pr_info(DRV ": SFP reg 0x%02x TX_DISABLE cleared\n", reg);
	}
}

int vep1400_board_init(void)
{
	adapter = vep1400_find_adapter();
	if (!adapter) {
		pr_warn(DRV ": no iSMT SMBus adapter, watchdog and SFP TX not handled\n");
		return -ENODEV;
	}
	pr_info(DRV ": iSMT bus %d (%s)\n", adapter->nr, adapter->name);

	client_pic = vep1400_client(VEP1400_I2C_PIC);
	client_pic2 = vep1400_client(VEP1400_I2C_PIC2);
	client_cpld = vep1400_client(VEP1400_I2C_CPLD);

	if (watchdog)
		vep1400_watchdog_off();
	if (sfp_tx)
		vep1400_sfp_tx_on();
	return 0;
}

void vep1400_board_exit(void)
{
	i2c_unregister_device(client_cpld);
	i2c_unregister_device(client_pic2);
	i2c_unregister_device(client_pic);
	client_cpld = NULL;
	client_pic2 = NULL;
	client_pic = NULL;

	if (adapter)
		i2c_put_adapter(adapter);
	adapter = NULL;
}
