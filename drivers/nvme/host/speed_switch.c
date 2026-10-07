// SPDX-License-Identifier: GPL-2.0
/*
 * NVMe link speed switch driver
 *
 * Adjusts the PCIe link rate of NVMe devices dynamically based on the I/O
 * workload: the link is downgraded to a configurable minimum rate during
 * periods of low activity to save power, and upgraded to the maximum
 * supported rate as soon as the workload requires it.
 *
 * Copyright (c) 2026 Hygon Information Technology Co., Ltd.
 * Copyright (c) 2026 Kylin Software Co., Ltd.
 *
 */

#include <linux/blk-mq.h>
#include <linux/math64.h>
#include <linux/pci.h>
#include <linux/percpu.h>
#include <linux/processor.h>

#include "nvme.h"

/*
 * PCIe link bandwidth in MB/s for each generation (rows, Gen1..Gen5) and
 * lane width (columns, x1..x16).  The table is used to derive the I/O
 * threshold exceed/below which the link can be upgraded/downgraded.
 */
static const u32 nvme_speed_table[][5] = {
	{  312,  625, 1250, 2500, 5000 },   /* Gen1 */
	{  625, 1250, 2500, 5000, 10000 },  /* Gen2 */
	{ 1000, 2000, 4000, 8000, 16000 },  /* Gen3 */
	{ 2000, 4000, 8000, 16000, 32000 }, /* Gen4 */
	{ 4000, 8000, 16000, 32000, 64000 },/* Gen5 */
};

static int nvme_bandwidth_index(enum pcie_link_width width)
{
	switch (width) {
	case PCIE_LNK_X1:
		return 0;
	case PCIE_LNK_X2:
		return 1;
	case PCIE_LNK_X4:
		return 2;
	case PCIE_LNK_X8:
		return 3;
	case PCIE_LNK_X16:
		return 4;
	default:
		return -EINVAL;
	}
}

/*
 * Read the maximum supported link rate from the Link Capability register.
 */
static int nvme_get_max_link_speed(struct pci_dev *pdev)
{
	u16 linkcap;

	if (pcie_capability_read_word(pdev, PCI_EXP_LNKCAP, &linkcap))
		return -EIO;

	return linkcap & PCI_EXP_LNKCAP_SLS;
}

/*
 * The transport serializes link retraining against controller shutdown.
 */
static void nvme_speed_switch_work(struct work_struct *work)
{
	struct nvme_speed_switch *sw = container_of(work, struct nvme_speed_switch, work);
	struct nvme_ctrl *ctrl = container_of(sw, struct nvme_ctrl, speed_switch);
	unsigned long flags;
	u8 target;

	if (!device_trylock(ctrl->dev))
		return;

	spin_lock_irqsave(&sw->state_lock, flags);
	if (!READ_ONCE(sw->enabled) || nvme_ctrl_state(ctrl) != NVME_CTRL_LIVE) {
		spin_unlock_irqrestore(&sw->state_lock, flags);
		device_unlock(ctrl->dev);
		return;
	}
	target = sw->target_speed;
	sw->switching = true;
	spin_unlock_irqrestore(&sw->state_lock, flags);
	(void)ctrl->ops->set_link_speed(ctrl, target);
	spin_lock_irqsave(&sw->state_lock, flags);
	sw->switching = false;
	spin_unlock_irqrestore(&sw->state_lock, flags);
	device_unlock(ctrl->dev);
}

/*
 * Compute the I/O threshold (in KB) for a monitoring window.
 *
 * The threshold is derived from the following constraint: for the link
 * speed to be upgraded, the transfer time of the data at the minimum
 * speed must be greater than the sum of the transfer time at maximum
 * speed and the link retraining time (100us):
 *
 *	data / min_bw >= data / max_bw + 100us
 *
 * which yields data >= min_bw * max_bw * 0.0001s / (max_bw - min_bw).
 * The bandwidths are taken from the link capability of the upstream port
 * and the link width capability of the device.
 */
static u32 nvme_calc_speed_threshold(struct nvme_speed_switch *sw,
				     enum pcie_link_width max_width)
{
	struct nvme_ctrl *ctrl = container_of(sw, struct nvme_ctrl, speed_switch);
	int bw_idx, min_gen = READ_ONCE(sw->min_speed), max_gen = sw->max_speed;
	u64 min_bw, max_bw, x, y;
	u32 threshold;

	if (min_gen < 1 || min_gen > 5 || max_gen < 1 || max_gen > 5) {
		dev_warn(ctrl->device,
			 "invalid link rate range for threshold: min=Gen%d, max=Gen%d\n",
			 min_gen, max_gen);
		return 0;
	}

	bw_idx = nvme_bandwidth_index(max_width);
	if (bw_idx < 0) {
		dev_warn(ctrl->device,
			 "unsupported link width (%d) for threshold calculation\n",
			 max_width);
		return 0;
	}

	min_bw = (u64)nvme_speed_table[min_gen - 1][bw_idx] * 1000;
	max_bw = (u64)nvme_speed_table[max_gen - 1][bw_idx] * 1000;
	if (min_bw >= max_bw) {
		dev_warn(ctrl->device,
			 "invalid bandwidth for threshold: min=%llu KB/s, max=%llu KB/s\n",
			 min_bw, max_bw);
		return 0;
	}

	x = min_bw * max_bw;
	y = 10000ULL * (max_bw - min_bw);
	threshold = div64_u64(x + (y >> 1), y);

	dev_dbg(ctrl->device,
		"I/O threshold: %u KB (min=Gen%d, max=Gen%d, width=x%d)\n",
		threshold, min_gen, max_gen, max_width);

	return threshold;
}

static void nvme_speed_switch_arm(struct nvme_speed_switch *sw)
{
	sw->idle_since = jiffies;
	sw->up_cnt = 0;
	sw->down_cnt = 0;
	sw->cur_speed = 0;
	sw->target_speed = sw->max_speed;
	atomic_set(&sw->timer_active, NVME_SPEED_TIMER_ACTIVE);
	mod_timer(&sw->timer, jiffies + msecs_to_jiffies(READ_ONCE(sw->monitor_interval)));
}

/* Called on the I/O submission path to accumulate the transferred bytes. */
void nvme_update_io_stats(struct nvme_ctrl *ctrl, struct request *req)
{
	struct nvme_speed_switch *sw = &ctrl->speed_switch;
	struct nvme_speed_switch_stats *stat;
	enum req_op op = req_op(req);
	unsigned int bytes = blk_rq_bytes(req);
	unsigned long flags;

	if (op != REQ_OP_READ && op != REQ_OP_WRITE)
		return;

	rcu_read_lock();
	if (!smp_load_acquire(&sw->enabled))
		goto unlock;

	stat = get_cpu_ptr(sw->stats);
	if (op == REQ_OP_READ)
		atomic64_add(bytes, &stat->read_bytes);
	else
		atomic64_add(bytes, &stat->write_bytes);
	put_cpu_ptr(sw->stats);

	spin_lock_irqsave(&sw->state_lock, flags);
	if (READ_ONCE(sw->enabled) &&
	    atomic_read(&sw->timer_active) == NVME_SPEED_TIMER_INACTIVE)
		nvme_speed_switch_arm(sw);
	spin_unlock_irqrestore(&sw->state_lock, flags);
unlock:
	rcu_read_unlock();
}
EXPORT_SYMBOL_GPL(nvme_update_io_stats);

static void nvme_clear_io_stats(struct nvme_speed_switch *sw)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		struct nvme_speed_switch_stats *stat = per_cpu_ptr(sw->stats, cpu);

		atomic64_set(&stat->read_bytes, 0);
		atomic64_set(&stat->write_bytes, 0);
	}
}

/*
 * Aggregate the per-CPU I/O counters of the last monitoring window and
 * decide the target rate.  Hysteresis counters are used to avoid
 * excessive rate switching when the workload fluctuates around the
 * threshold: the rate is only upgraded after the threshold was exceeded
 * for a number of consecutive windows, and only downgraded after it
 * stayed below the threshold for a number of consecutive windows.  When
 * no I/O was observed for 10 seconds the monitoring is stopped.
 */
static int nvme_check_io_and_decide_speed(struct nvme_speed_switch *sw,
					  bool *io_activity)
{
	struct nvme_ctrl *ctrl = container_of(sw, struct nvme_ctrl, speed_switch);
	u64 read_bytes = 0, write_bytes = 0;
	unsigned long read_kb, write_kb;
	int cpu;

	for_each_possible_cpu(cpu) {
		struct nvme_speed_switch_stats *stat = per_cpu_ptr(sw->stats, cpu);

		read_bytes += atomic64_xchg(&stat->read_bytes, 0);
		write_bytes += atomic64_xchg(&stat->write_bytes, 0);
	}

	if (read_bytes || write_bytes)
		sw->idle_since = jiffies;
	*io_activity = time_before(jiffies,
				   sw->idle_since + msecs_to_jiffies(10000));

	read_kb = read_bytes / 1024;
	write_kb = write_bytes / 1024;
	dev_dbg(ctrl->device,
		"I/O in window: read=%lu KB, write=%lu KB, threshold=%u KB\n",
		read_kb, write_kb, READ_ONCE(sw->threshold));

	if (read_kb >= READ_ONCE(sw->threshold) || write_kb >= READ_ONCE(sw->threshold)) {
		sw->up_cnt++;
		sw->down_cnt = 0;
	} else {
		sw->down_cnt++;
		sw->up_cnt = 0;
	}

	if (sw->up_cnt > READ_ONCE(sw->up_threshold)) {
		sw->up_cnt = 0;
		return sw->max_speed;
	}

	if (sw->down_cnt > READ_ONCE(sw->down_threshold) || !*io_activity) {
		sw->down_cnt = 0;
		return READ_ONCE(sw->min_speed);
	}

	return sw->target_speed;
}

static void nvme_speed_switch_timer_fn(struct timer_list *t)
{
	struct nvme_speed_switch *sw = container_of(t, struct nvme_speed_switch, timer);
	bool io_activity = true;
	unsigned long flags;

	spin_lock_irqsave(&sw->state_lock, flags);
	if (!READ_ONCE(sw->enabled)) {
		atomic_set(&sw->timer_active, NVME_SPEED_TIMER_INACTIVE);
		goto unlock;
	}

	WRITE_ONCE(sw->target_speed, nvme_check_io_and_decide_speed(sw, &io_activity));
	if (sw->target_speed != READ_ONCE(sw->cur_speed))
		schedule_work(&sw->work);

	if (!io_activity && !sw->switching && sw->target_speed == sw->cur_speed) {
		atomic_set(&sw->timer_active, NVME_SPEED_TIMER_INACTIVE);
		goto unlock;
	}
	mod_timer(t, jiffies + msecs_to_jiffies(READ_ONCE(sw->monitor_interval)));
unlock:
	spin_unlock_irqrestore(&sw->state_lock, flags);
}

static void nvme_speed_switch_quiesce(struct nvme_speed_switch *sw)
{
	unsigned long flags;

	spin_lock_irqsave(&sw->state_lock, flags);
	WRITE_ONCE(sw->enabled, false);
	spin_unlock_irqrestore(&sw->state_lock, flags);
	synchronize_rcu();
	timer_shutdown_sync(&sw->timer);
	cancel_work_sync(&sw->work);
	atomic_set(&sw->timer_active, NVME_SPEED_TIMER_INACTIVE);
}

static void nvme_speed_switch_enable(struct nvme_ctrl *ctrl)
{
	struct nvme_speed_switch *sw = &ctrl->speed_switch;

	nvme_clear_io_stats(sw);
	timer_setup(&sw->timer, nvme_speed_switch_timer_fn, 0);
	smp_store_release(&sw->enabled, true);
	nvme_speed_switch_start(ctrl);
}

int nvme_speed_switch_set_enabled(struct nvme_ctrl *ctrl, bool enabled)
{
	struct nvme_speed_switch *sw = &ctrl->speed_switch;
	int ret = 0;

	mutex_lock(&sw->lock);
	nvme_speed_switch_quiesce(sw);
	if (enabled) {
		nvme_speed_switch_enable(ctrl);
	} else if (device_trylock(ctrl->dev)) {
		ret = ctrl->ops->set_link_speed(ctrl, sw->max_speed);
		device_unlock(ctrl->dev);
	} else {
		ret = -EBUSY;
	}
	mutex_unlock(&sw->lock);
	return ret;
}

int nvme_speed_switch_set_min(struct nvme_ctrl *ctrl, u32 speed)
{
	struct nvme_speed_switch *sw = &ctrl->speed_switch;
	bool enabled;

	if (!speed || speed >= sw->max_speed)
		return -EINVAL;
	mutex_lock(&sw->lock);
	enabled = READ_ONCE(sw->enabled);
	nvme_speed_switch_quiesce(sw);
	WRITE_ONCE(sw->min_speed, speed);
	WRITE_ONCE(sw->threshold, nvme_calc_speed_threshold(sw, sw->max_width));
	if (enabled)
		nvme_speed_switch_enable(ctrl);
	mutex_unlock(&sw->lock);
	return 0;
}

static void nvme_speed_switch_params_init(struct nvme_speed_switch *sw)
{
	sw->monitor_interval = 100;
	sw->min_speed = PCI_EXP_LNKSTA_CLS_2_5GB;
	/* Upgrade immediately once the threshold is exceeded. */
	sw->up_threshold = 0;
	/* Downgrade after 10 consecutive below-threshold windows. */
	sw->down_threshold = 10;
}

void nvme_speed_switch_init(struct nvme_ctrl *ctrl)
{
	struct nvme_speed_switch *sw = &ctrl->speed_switch;
	struct pci_dev *pdev;
	u16 link_status;
	int max_speed, ret;

	mutex_init(&sw->lock);
	spin_lock_init(&sw->state_lock);
	if (!dev_is_pci(ctrl->dev) || !ctrl->ops->set_link_speed)
		return;

	pdev = to_pci_dev(ctrl->dev);
	if (!pdev->bus->self) {
		dev_err(ctrl->device,
			"link rate switching requires a PCIe upstream port\n");
		return;
	}

	nvme_speed_switch_params_init(sw);

	max_speed = min(nvme_get_max_link_speed(pdev),
			nvme_get_max_link_speed(pdev->bus->self));
	if (max_speed <= sw->min_speed || max_speed > ARRAY_SIZE(nvme_speed_table))
		return;
	if (pcie_capability_read_word(pdev, PCI_EXP_LNKSTA, &link_status))
		return;
	link_status &= PCI_EXP_LNKSTA_CLS;
	if (!link_status || link_status > max_speed)
		return;
	sw->max_speed = max_speed;
	sw->max_width = pcie_get_width_cap(pdev);

	sw->stats = alloc_percpu(struct nvme_speed_switch_stats);
	if (!sw->stats) {
		dev_err(ctrl->device, "failed to allocate per-CPU I/O statistics\n");
		return;
	}
	nvme_clear_io_stats(sw);

	WRITE_ONCE(sw->cur_speed, link_status);
	WRITE_ONCE(sw->threshold, nvme_calc_speed_threshold(sw, sw->max_width));
	if (!READ_ONCE(sw->threshold)) {
		dev_err(ctrl->device, "failed to compute speed switch threshold\n");
		free_percpu(sw->stats);
		sw->stats = NULL;
		return;
	}

	INIT_WORK(&sw->work, nvme_speed_switch_work);
	timer_setup(&sw->timer, nvme_speed_switch_timer_fn, 0);
	atomic_set(&sw->timer_active, NVME_SPEED_TIMER_INACTIVE);
	sw->initialized = true;
	smp_store_release(&sw->enabled, true);

	ret = sysfs_create_group(&ctrl->device->kobj, &nvme_speed_attr_group);
	if (ret) {
		dev_err(ctrl->device,
			"failed to create link rate switching sysfs group (%d)\n",
			ret);
		nvme_speed_switch_quiesce(sw);
		free_percpu(sw->stats);
		sw->stats = NULL;
		sw->initialized = false;
		return;
	}

	dev_info(ctrl->device,
		 "NVMe link rate switching initialized (min Gen%u, max Gen%d)\n",
		 sw->min_speed, sw->max_speed);
}

void nvme_speed_switch_start(struct nvme_ctrl *ctrl)
{
	struct nvme_speed_switch *sw = &ctrl->speed_switch;
	unsigned long flags;

	rcu_read_lock();
	if (smp_load_acquire(&sw->enabled)) {
		spin_lock_irqsave(&sw->state_lock, flags);
		if (READ_ONCE(sw->enabled))
			nvme_speed_switch_arm(sw);
		spin_unlock_irqrestore(&sw->state_lock, flags);
	}
	rcu_read_unlock();
}
EXPORT_SYMBOL_GPL(nvme_speed_switch_start);

void nvme_speed_switch_exit(struct nvme_ctrl *ctrl)
{
	struct nvme_speed_switch *sw = &ctrl->speed_switch;

	if (!sw->initialized)
		return;

	sysfs_remove_group(&ctrl->device->kobj, &nvme_speed_attr_group);
	sw->initialized = false;
	nvme_speed_switch_quiesce(sw);

	free_percpu(sw->stats);
	sw->stats = NULL;
}
