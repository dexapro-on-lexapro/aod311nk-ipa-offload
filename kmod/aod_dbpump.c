// SPDX-License-Identifier: GPL-2.0
/*
 * aod_dbpump: IPA TX-completion "doorbell pump" for the AOD311NK.
 *
 * Background (r8168 8.051.02-b22_q0, CodeLinaro data-eth LE.UM.6.3.6 SDX65):
 * IPA learns that the RTL8111K finished transmitting offloaded packets
 * only when the Linux r8168 interrupt path runs rtl8168_lib_tx_interrupt(),
 * which does writel_relaxed(1, db_tx) ("IPA tx interrupt is handled by sw
 * path"). Offloaded traffic causes almost no Linux interrupts, so IPA is
 * notified about 18x/s and the offloaded downlink trickles at about 20 KB/s.
 * This module performs that same doorbell write periodically. The driver
 * already writes it unconditionally on every ISR run, so extra writes are
 * part of the normal protocol.
 *
 * Built against vanilla 5.4.265 headers for a Qualcomm/Android-patched
 * kernel, so it deliberately avoids embedding or poking kernel structs:
 *  - a kthread + usleep_range() instead of an embedded struct hrtimer;
 *  - only exported functions and opaque pointers;
 *  - __this_module is emitted with the device's real layout (see Makefile).
 * kallsyms_lookup_name is not exported on this kernel, so the loader passes
 * &db_tx (and the BSS bounds) from /proc/kallsyms; all are validated.
 *
 * Safety:
 *  - inert by default: enable=0 means the thread sleeps 20 ms and writes nothing;
 *  - db_tx is re-read on every pass and only written when non-NULL
 *    (rtl8168_release_event() sets it to NULL on teardown);
 *  - period clamped to [20 us, 100 ms];
 *  - rmmod stops the thread; reboot removes everything.
 * Caveat: do not bring eth0 down / tear down IOSS while enable=1.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/mm.h>

static unsigned long db_tx_addr;
module_param(db_tx_addr, ulong, 0444);
MODULE_PARM_DESC(db_tx_addr, "Address of the r8168 global db_tx (from /proc/kallsyms)");

static unsigned long bss_start;
module_param(bss_start, ulong, 0444);
MODULE_PARM_DESC(bss_start, "__bss_start (from /proc/kallsyms), for validation");

static unsigned long bss_end;
module_param(bss_end, ulong, 0444);
MODULE_PARM_DESC(bss_end, "__bss_stop (from /proc/kallsyms), for validation");

/* ioremap ranges created by rtl8168_request_event (from /proc/vmallocinfo) */
static unsigned long db_lo1, db_hi1, db_lo2, db_hi2;
module_param(db_lo1, ulong, 0444);
module_param(db_hi1, ulong, 0444);
module_param(db_lo2, ulong, 0444);
module_param(db_hi2, ulong, 0444);
MODULE_PARM_DESC(db_lo1, "start of 1st rtl8168_request_event ioremap (vmallocinfo)");

static unsigned int period_us = 200;
module_param(period_us, uint, 0644);
MODULE_PARM_DESC(period_us, "Doorbell period in microseconds (20..100000)");

static bool enable;
module_param(enable, bool, 0644);
MODULE_PARM_DESC(enable, "1 = ring the IPA TX doorbell each period (default 0)");

static unsigned long rings;
module_param(rings, ulong, 0444);
MODULE_PARM_DESC(rings, "Doorbell writes performed");

static unsigned long null_ticks;
module_param(null_ticks, ulong, 0444);
MODULE_PARM_DESC(null_ticks, "Enabled passes where db_tx was NULL");

static void __iomem **db_tx_p;
static struct task_struct *pump_task;

static int aod_dbpump_fn(void *unused)
{
	while (!kthread_should_stop()) {
		unsigned int p;

		if (!READ_ONCE(enable)) {
			msleep(20);
			continue;
		}

		{
			void __iomem *db = READ_ONCE(*db_tx_p);

			if (db) {
				writel_relaxed(1, db);
				rings++;
			} else {
				null_ticks++;
			}
		}

		p = clamp_t(unsigned int, READ_ONCE(period_us), 20, 100000);
		usleep_range(p, p + p / 4 + 1);
	}
	return 0;
}

static int __init aod_dbpump_init(void)
{
	void *cur;

	if (!db_tx_addr || !bss_start || !bss_end) {
		pr_err("aod_dbpump: db_tx_addr, bss_start and bss_end are required\n");
		return -EINVAL;
	}
	if (db_tx_addr & 3) {
		pr_err("aod_dbpump: db_tx_addr %lx not aligned\n", db_tx_addr);
		return -EINVAL;
	}
	if (db_tx_addr < bss_start || db_tx_addr + sizeof(void *) > bss_end) {
		pr_err("aod_dbpump: db_tx_addr %lx outside BSS [%lx,%lx)\n",
		       db_tx_addr, bss_start, bss_end);
		return -EINVAL;
	}
	if (!virt_addr_valid((void *)db_tx_addr)) {
		pr_err("aod_dbpump: db_tx_addr %lx not a valid lowmem address\n", db_tx_addr);
		return -EINVAL;
	}

	db_tx_p = (void __iomem **)db_tx_addr;
	cur = (void __force *)READ_ONCE(*db_tx_p);
	if (!cur) {
		pr_err("aod_dbpump: *db_tx is NULL (IOSS TX event not set up), refusing\n");
		return -EINVAL;
	}
	{
		unsigned long c = (unsigned long)cur;
		bool in1 = db_lo1 && c >= db_lo1 && c + 4 <= db_hi1;
		bool in2 = db_lo2 && c >= db_lo2 && c + 4 <= db_hi2;

		if (!in1 && !in2) {
			pr_err("aod_dbpump: *db_tx = %px not inside rtl8168_request_event ioremaps [%lx,%lx) [%lx,%lx), refusing\n",
			       cur, db_lo1, db_hi1, db_lo2, db_hi2);
			return -EINVAL;
		}
	}

	pr_info("aod_dbpump: db_tx@%lx = %px, period_us=%u, enable=%d\n",
		db_tx_addr, cur, period_us, enable);

	pump_task = kthread_run(aod_dbpump_fn, NULL, "aod_dbpump");
	if (IS_ERR(pump_task)) {
		pr_err("aod_dbpump: kthread_run failed\n");
		return PTR_ERR(pump_task);
	}
	return 0;
}

static void __exit aod_dbpump_exit(void)
{
	kthread_stop(pump_task);
	pr_info("aod_dbpump: unloaded, rings=%lu null_ticks=%lu\n",
		rings, null_ticks);
}

module_init(aod_dbpump_init);
module_exit(aod_dbpump_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("AOD311NK IPA TX-completion doorbell pump (r8168 lib sw path)");
