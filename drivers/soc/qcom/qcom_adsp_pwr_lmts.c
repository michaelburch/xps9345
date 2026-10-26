// SPDX-License-Identifier: GPL-2.0
/*
 * Tell the ADSP when the system enters and leaves sleep, like Windows does.
 *
 * Windows' PEP (qcpep8380.sys) sends a MODERN_STANDBY_STATE message on the
 * APPS_ADSP_PWR_LMTS_GLINK_PORT channel when the platform enters Modern
 * Standby (state 1) and when it leaves it (state 0). On entry the ADSP stops
 * its periodic power-limits timer.
 *
 * The suspend notifier runs after the EC and before QCMB, in both directions.
 * Device-PM callbacks retain the hibernation path but skip notifier-owned
 * transitions.
 */
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/pm.h>
#include <linux/rpmsg.h>
#include <linux/soc/qcom/adsp_pwr_lmts.h>
#include <linux/suspend.h>

#define PWR_LMTS_MODERN_STANDBY_STATE	1

struct pwr_lmts_msg {
	__le32 size;
	__le32 type;
	__le32 count;
	__le32 state;
	__le32 reserved[2];
} __packed;

enum pwr_lmts_state {
	PWR_LMTS_AWAKE,
	PWR_LMTS_SUSPENDED,
	PWR_LMTS_UNKNOWN,
};

/* The ADSP service is shared with the PMIC GLINK mailbox client. */
static DEFINE_MUTEX(pwr_lmts_lock);
static struct rpmsg_device *pwr_lmts_rpdev;
static enum pwr_lmts_state pwr_lmts_state;
static bool pwr_lmts_prepared;

static int pwr_lmts_send_state(struct rpmsg_device *rpdev, u32 state)
{
	struct pwr_lmts_msg msg = {
		.size = cpu_to_le32(sizeof(msg)),
		.type = cpu_to_le32(PWR_LMTS_MODERN_STANDBY_STATE),
		.count = cpu_to_le32(1),
		.state = cpu_to_le32(state),
	};
	int ret;

	ret = rpmsg_send(rpdev->ept, &msg, sizeof(msg));
	if (ret)
		dev_warn(&rpdev->dev, "failed to send standby state %u: %d\n", state, ret);

	return ret;
}

static int pwr_lmts_set_state(bool suspended)
{
	int ret;

	lockdep_assert_held(&pwr_lmts_lock);
	if (!pwr_lmts_rpdev)
		return -ENODEV;

	pwr_lmts_state = PWR_LMTS_UNKNOWN;
	ret = pwr_lmts_send_state(pwr_lmts_rpdev, suspended);
	if (!ret) {
		pwr_lmts_state = suspended ? PWR_LMTS_SUSPENDED : PWR_LMTS_AWAKE;
		dev_info(&pwr_lmts_rpdev->dev, "PLD %s notification complete (state %u)\n",
			 suspended ? "standby" : "awake", suspended);
	}

	return ret;
}

int qcom_adsp_pwr_lmts_check_state(bool suspended)
{
	int ret = 0;

	mutex_lock(&pwr_lmts_lock);
	if (!pwr_lmts_rpdev)
		ret = -ENODEV;
	else if (pwr_lmts_state == PWR_LMTS_UNKNOWN)
		ret = -EIO;
	else if (suspended ? !pwr_lmts_prepared || pwr_lmts_state != PWR_LMTS_SUSPENDED :
		 pwr_lmts_prepared || pwr_lmts_state != PWR_LMTS_AWAKE)
		ret = -EBUSY;
	mutex_unlock(&pwr_lmts_lock);

	return ret;
}
EXPORT_SYMBOL_GPL(qcom_adsp_pwr_lmts_check_state);

static int pwr_lmts_pm_notify(struct notifier_block *nb, unsigned long action, void *unused)
{
	int ret = 0;

	mutex_lock(&pwr_lmts_lock);
	switch (action) {
	case PM_SUSPEND_PREPARE:
		if (!pwr_lmts_rpdev)
			break;
		if (pwr_lmts_prepared || pwr_lmts_state != PWR_LMTS_AWAKE) {
			dev_err(&pwr_lmts_rpdev->dev,
				"PLD state unresolved; refusing suspend, cold boot required\n");
			ret = -EBUSY;
			break;
		}
		ret = pwr_lmts_set_state(true);
		if (ret) {
			/* PM rollback excludes the notifier that failed preparation. */
			if (pwr_lmts_set_state(false))
				dev_err(&pwr_lmts_rpdev->dev,
					"PLD preparation rollback failed; cold boot required\n");
		} else {
			pwr_lmts_prepared = true;
		}
		break;
	case PM_POST_SUSPEND:
		if (!pwr_lmts_prepared)
			break;
		pwr_lmts_prepared = false;
		ret = pwr_lmts_set_state(false);
		if (ret)
			pr_err("ADSP PLD awake restoration failed: %d; cold boot required\n", ret);
		break;
	}
	mutex_unlock(&pwr_lmts_lock);

	return action == PM_SUSPEND_PREPARE ? notifier_from_errno(ret) : NOTIFY_DONE;
}

static struct notifier_block pwr_lmts_pm_nb = {
	.notifier_call = pwr_lmts_pm_notify,
	.priority = 1,
};

static int pwr_lmts_callback(struct rpmsg_device *rpdev, void *data, int len,
			     void *priv, u32 addr)
{
	return 0;
}

static int pwr_lmts_probe(struct rpmsg_device *rpdev)
{
	int ret;

	mutex_lock(&pwr_lmts_lock);
	if (pwr_lmts_rpdev) {
		mutex_unlock(&pwr_lmts_lock);
		return dev_err_probe(&rpdev->dev, -EBUSY, "ADSP PLD endpoint already bound\n");
	}
	if (pwr_lmts_prepared || pwr_lmts_state != PWR_LMTS_AWAKE) {
		mutex_unlock(&pwr_lmts_lock);
		return dev_err_probe(&rpdev->dev, -EIO,
				     "ADSP PLD state lost; cold boot required before rebinding\n");
	}
	pwr_lmts_rpdev = rpdev;
	mutex_unlock(&pwr_lmts_lock);

	ret = register_pm_notifier(&pwr_lmts_pm_nb);
	if (ret) {
		mutex_lock(&pwr_lmts_lock);
		pwr_lmts_rpdev = NULL;
		mutex_unlock(&pwr_lmts_lock);
		return dev_err_probe(&rpdev->dev, ret, "Failed to register PLD PM notifier\n");
	}

	return 0;
}

static void pwr_lmts_remove(struct rpmsg_device *rpdev)
{
	unregister_pm_notifier(&pwr_lmts_pm_nb);
	mutex_lock(&pwr_lmts_lock);
	if (pwr_lmts_prepared || pwr_lmts_state != PWR_LMTS_AWAKE) {
		pwr_lmts_state = PWR_LMTS_UNKNOWN;
		dev_err(&rpdev->dev, "ADSP PLD endpoint lost with unresolved state; cold boot required\n");
	}
	pwr_lmts_rpdev = NULL;
	mutex_unlock(&pwr_lmts_lock);
}

static int pwr_lmts_suspend(struct device *dev)
{
	int ret = 0;

	mutex_lock(&pwr_lmts_lock);
	if (!pwr_lmts_prepared && pwr_lmts_state != PWR_LMTS_AWAKE) {
		ret = -EBUSY;
	} else if (!pwr_lmts_prepared) {
		ret = pwr_lmts_set_state(true);
		if (ret && pwr_lmts_set_state(false))
			dev_err(dev, "PLD device sleep rollback failed; cold boot required\n");
	}
	mutex_unlock(&pwr_lmts_lock);
	if (ret)
		dev_warn(dev, "PLD device sleep notification failed: %d\n", ret);

	return ret;
}

static int pwr_lmts_resume(struct device *dev)
{
	int ret = 0;

	mutex_lock(&pwr_lmts_lock);
	if (!pwr_lmts_prepared)
		ret = pwr_lmts_set_state(false);
	mutex_unlock(&pwr_lmts_lock);
	if (ret)
		dev_warn(dev, "PLD device awake notification failed: %d\n", ret);

	return ret;
}

static DEFINE_SIMPLE_DEV_PM_OPS(pwr_lmts_pm_ops, pwr_lmts_suspend, pwr_lmts_resume);

static const struct rpmsg_device_id pwr_lmts_id_table[] = {
	{ .name = "APPS_ADSP_PWR_LMTS_GLINK_PORT" },
	{ }
};
MODULE_DEVICE_TABLE(rpmsg, pwr_lmts_id_table);

static struct rpmsg_driver pwr_lmts_driver = {
	.drv = {
		.name = "qcom_adsp_pwr_lmts",
		.pm = pm_sleep_ptr(&pwr_lmts_pm_ops),
	},
	.id_table = pwr_lmts_id_table,
	.probe = pwr_lmts_probe,
	.remove = pwr_lmts_remove,
	.callback = pwr_lmts_callback,
};
module_rpmsg_driver(pwr_lmts_driver);

MODULE_DESCRIPTION("Qualcomm ADSP power-limits Modern Standby notification");
MODULE_LICENSE("GPL");
