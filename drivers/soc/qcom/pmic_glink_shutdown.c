#include <linux/auxiliary_bus.h>
#include <linux/bitfield.h>
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/reboot.h>
#include <linux/slab.h>
#include <linux/soc/qcom/adsp_pwr_lmts.h>
#include <linux/soc/qcom/pdr.h>
#include <linux/soc/qcom/pmic_glink.h>
#include <linux/spinlock.h>
#include <linux/suspend.h>
#include <linux/unaligned.h>
#include <linux/workqueue.h>

#define QCMB_OWNER		0x8010
#define QCMB_READ		0x80
#define QCMB_WRITE		0x81
#define QCMB_CONNECTED		BIT(0)
#define QCMB_STATUS		GENMASK(3, 1)
#define QCMB_BUSY		0x2
#define QCMB_DONE		0x4
#define QCMB_CONNECT		1
#define QCMB_POWEROFF		0x2120
#define QCMB_REASON_OFF		5
#define QCMB_ACK			3
#define QCMB_REASON_AWAKE		1
#define QCMB_REASON_SUSPEND	2
#define QCMB_TIMEOUT_MS		1000

/* Keep the entry/exit policy fixed for the lifetime of the driver. */
static bool suspend_disabled = true;
module_param(suspend_disabled, bool, 0444);
MODULE_PARM_DESC(suspend_disabled,
		 "Skip suspend/resume mailbox requests (default: true), retaining poweroff preparation");

struct qcmb_request {
	struct pmic_glink_hdr hdr;
	__le32 reserved[2];
	__le32 control;
	__le32 reason;
	u8 padding[36];
};

static_assert(sizeof(struct qcmb_request) == 64);
static_assert(offsetof(struct qcmb_request, control) == 20);
static_assert(offsetof(struct qcmb_request, reason) == 24);

static size_t qcmb_pack(struct qcmb_request *request, u32 opcode, u32 control, u32 reason)
{
	*request = (struct qcmb_request) {
		.hdr.owner = cpu_to_le32(QCMB_OWNER),
		.hdr.type = cpu_to_le32(PMIC_GLINK_REQ_RESP),
		.hdr.opcode = cpu_to_le32(opcode),
		.control = cpu_to_le32(control),
		.reason = cpu_to_le32(reason),
	};
	return opcode == QCMB_READ ? sizeof(request->hdr) : sizeof(*request);
}

static int qcmb_decode(u32 expected, const void *data, size_t len, u32 *status)
{
	const u8 *bytes = data;

	if (len < sizeof(struct pmic_glink_hdr) ||
	    get_unaligned_le32(bytes) != QCMB_OWNER ||
	    get_unaligned_le32(bytes + 4) != PMIC_GLINK_REQ_RESP ||
	    get_unaligned_le32(bytes + 8) != expected)
		return -ENOMSG;
	if (len != (expected == QCMB_READ ? 64 : 16))
		return -EPROTO;
	if (get_unaligned_le32(bytes + (expected == QCMB_READ ? 60 : 12)))
		return -EREMOTEIO;
	if (expected == QCMB_READ)
		*status = get_unaligned_le32(bytes + 16);
	return 0;
}

struct qcmb_test {
	struct device *dev;
	struct pmic_glink_client *client;
	struct mutex lock;
	spinlock_t rx_lock;
	struct completion reply;
	struct notifier_block reboot;
	struct notifier_block pm;
	struct work_struct initialize_work;
	u32 expected;
	u32 status;
	int result;
	bool waiting;
	bool ready;
	bool poisoned;
	bool stopping;
	bool resume_needed;
};

static void qcmb_receive(const void *data, size_t len, void *priv)
{
	struct qcmb_test *test = priv;
	unsigned long flags;
	int ret;

	spin_lock_irqsave(&test->rx_lock, flags);
	if (!test->waiting)
		goto unlock;
	ret = qcmb_decode(test->expected, data, len, &test->status);
	if (ret == -ENOMSG)
		goto unlock;
	test->result = ret;
	test->waiting = false;
	complete(&test->reply);
unlock:
	spin_unlock_irqrestore(&test->rx_lock, flags);
}

static void qcmb_initialize(struct work_struct *work);

static void qcmb_service(void *priv, int state)
{
	struct qcmb_test *test = priv;
	unsigned long flags;

	spin_lock_irqsave(&test->rx_lock, flags);
	if (state != SERVREG_SERVICE_STATE_UP) {
		if (test->ready)
			test->poisoned = true;
		if (test->waiting) {
			test->result = -ECONNRESET;
			test->waiting = false;
			complete(&test->reply);
		}
	}
	test->ready = state == SERVREG_SERVICE_STATE_UP;
	if (test->ready && !test->poisoned && !test->stopping)
		schedule_work(&test->initialize_work);
	spin_unlock_irqrestore(&test->rx_lock, flags);
}

static int qcmb_transfer(struct qcmb_test *test, u32 opcode, u32 control, u32 reason)
{
	struct qcmb_request request;
	unsigned long flags;
	size_t size;
	int ret;

	spin_lock_irqsave(&test->rx_lock, flags);
	if (test->poisoned || !test->ready) {
		ret = test->poisoned ? -EIO : -ENOTCONN;
		spin_unlock_irqrestore(&test->rx_lock, flags);
		return ret;
	}
	reinit_completion(&test->reply);
	test->expected = opcode;
	test->result = -ETIMEDOUT;
	test->waiting = true;
	spin_unlock_irqrestore(&test->rx_lock, flags);

	size = qcmb_pack(&request, opcode, control, reason);
	ret = pmic_glink_send(test->client, &request, size);
	if (!ret && !wait_for_completion_timeout(&test->reply,
					       msecs_to_jiffies(QCMB_TIMEOUT_MS)))
		ret = -ETIMEDOUT;

	spin_lock_irqsave(&test->rx_lock, flags);
	if (!ret)
		ret = test->poisoned ? -ECONNRESET : test->result;
	test->waiting = false;
	if (ret)
		test->poisoned = true;
	spin_unlock_irqrestore(&test->rx_lock, flags);
	return ret;
}

static int qcmb_wait(struct qcmb_test *test, bool connecting)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(QCMB_TIMEOUT_MS);
	unsigned long flags;
	int ret;

	do {
		ret = qcmb_transfer(test, QCMB_READ, 0, 0);
		if (ret)
			return ret;
		if (connecting) {
			if (test->status & QCMB_CONNECTED)
				return 0;
		} else {
			if (!(test->status & QCMB_CONNECTED)) {
				ret = -ENOTCONN;
				goto poison;
			}
			if ((test->status & QCMB_STATUS) == QCMB_DONE)
				return 0;
			if ((test->status & QCMB_STATUS) != QCMB_BUSY) {
				ret = -EREMOTEIO;
				goto poison;
			}
		}
		msleep(100);
	} while (time_before(jiffies, deadline));
	ret = -ETIMEDOUT;
poison:
	spin_lock_irqsave(&test->rx_lock, flags);
	test->poisoned = true;
	spin_unlock_irqrestore(&test->rx_lock, flags);
	return ret;
}

static int qcmb_connect(struct qcmb_test *test)
{
	int ret;

	ret = qcmb_transfer(test, QCMB_READ, 0, 0);
	if (ret || (test->status & QCMB_CONNECTED))
		return ret;
	ret = qcmb_transfer(test, QCMB_WRITE, QCMB_CONNECT, 0);
	if (ret)
		return ret;
	return qcmb_wait(test, true);
}

static void qcmb_initialize(struct work_struct *work)
{
	struct qcmb_test *test = container_of(work, struct qcmb_test, initialize_work);
	int ret;

	mutex_lock(&test->lock);
	ret = qcmb_connect(test);
	if (ret)
		dev_err(test->dev, "Mailbox initialization failed: %d\n", ret);
	else
		dev_info(test->dev, "Mailbox initialized, status %#x\n", test->status);
	mutex_unlock(&test->lock);
}

static void qcmb_stop(void *data)
{
	struct qcmb_test *test = data;
	unsigned long flags;

	spin_lock_irqsave(&test->rx_lock, flags);
	test->stopping = true;
	spin_unlock_irqrestore(&test->rx_lock, flags);
	cancel_work_sync(&test->initialize_work);
}

static int qcmb_wait_idle(struct qcmb_test *test)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(QCMB_TIMEOUT_MS);
	unsigned long flags;
	int ret;

	do {
		ret = qcmb_transfer(test, QCMB_READ, 0, 0);
		if (ret)
			return ret;
		if (!(test->status & QCMB_CONNECTED)) {
			ret = -ENOTCONN;
			goto poison;
		}
		if (!(test->status & QCMB_STATUS))
			return 0;
		if ((test->status & QCMB_STATUS) != QCMB_DONE) {
			ret = -EREMOTEIO;
			goto poison;
		}
		msleep(100);
	} while (time_before(jiffies, deadline));
	ret = -ETIMEDOUT;
poison:
	spin_lock_irqsave(&test->rx_lock, flags);
	test->poisoned = true;
	spin_unlock_irqrestore(&test->rx_lock, flags);
	return ret;
}

static int qcmb_suspend_state(struct qcmb_test *test, u32 reason)
{
	int ret;

	ret = qcmb_connect(test);
	if (ret)
		return ret;
	if (test->status & QCMB_STATUS)
		return -EBUSY;
	if (reason == QCMB_REASON_SUSPEND)
		test->resume_needed = true;
	ret = qcmb_transfer(test, QCMB_WRITE, QCMB_POWEROFF, reason);
	if (!ret)
		ret = qcmb_wait(test, false);
	if (!ret)
		ret = qcmb_transfer(test, QCMB_WRITE, QCMB_ACK, reason);
	if (!ret)
		ret = qcmb_wait_idle(test);
	return ret;
}

static int qcmb_pm(struct notifier_block *notifier, unsigned long action, void *unused)
{
	struct qcmb_test *test = container_of(notifier, struct qcmb_test, pm);
	int ret = 0;

	if (action != PM_SUSPEND_PREPARE && action != PM_POST_SUSPEND)
		return NOTIFY_DONE;
	if (suspend_disabled)
		return NOTIFY_DONE;
	flush_work(&test->initialize_work);
	mutex_lock(&test->lock);
	if (action == PM_SUSPEND_PREPARE) {
		ret = test->resume_needed ? -EBUSY :
			qcom_adsp_pwr_lmts_check_state(true);
		if (!ret)
			ret = qcmb_suspend_state(test, QCMB_REASON_SUSPEND);
		if (ret) {
			dev_err(test->dev, "Suspend preparation failed: %d, status %#x, restore needed %u\n",
				ret, test->status, test->resume_needed);
			if (test->resume_needed)
				dev_err(test->dev, "Mailbox state uncertain; cold boot required before further suspend tests\n");
		} else {
			dev_info(test->dev, "Suspend mailbox preparation complete (reason 2)\n");
		}
	} else if (test->resume_needed) {
		ret = qcom_adsp_pwr_lmts_check_state(false);
		if (!ret)
			ret = qcmb_suspend_state(test, QCMB_REASON_AWAKE);
		if (ret) {
			dev_err(test->dev, "Resume mailbox restoration failed: %d, status %#x; cold boot required\n",
				ret, test->status);
		} else {
			test->resume_needed = false;
			dev_info(test->dev, "Resume mailbox restoration complete (reason 1)\n");
		}
	}
	mutex_unlock(&test->lock);
	return action == PM_SUSPEND_PREPARE ? notifier_from_errno(ret) : NOTIFY_DONE;
}

static void qcmb_unregister_pm(void *data)
{
	struct qcmb_test *test = data;

	unregister_pm_notifier(&test->pm);
}

static int qcmb_reboot(struct notifier_block *notifier, unsigned long action, void *unused)
{
	struct qcmb_test *test = container_of(notifier, struct qcmb_test, reboot);
	int ret;

	if (action != SYS_POWER_OFF)
		return NOTIFY_DONE;
	flush_work(&test->initialize_work);
	mutex_lock(&test->lock);
	ret = qcmb_connect(test);
	if (!ret && (test->status & QCMB_STATUS))
		ret = -EBUSY;
	if (!ret)
		ret = qcmb_transfer(test, QCMB_WRITE, QCMB_POWEROFF, QCMB_REASON_OFF);
	if (!ret)
		ret = qcmb_wait(test, false);
	if (ret)
		dev_err(test->dev, "Poweroff preparation failed: %d, status %#x\n",
			ret, test->status);
	else
		dev_info(test->dev, "Poweroff mailbox preparation complete\n");
	mutex_unlock(&test->lock);
	return NOTIFY_DONE;
}

static int qcmb_probe(struct auxiliary_device *adev, const struct auxiliary_device_id *id)
{
	struct device *dev = &adev->dev;
	struct qcmb_test *test;
	int ret;

	if (!device_link_add(dev, dev->parent, DL_FLAG_AUTOREMOVE_CONSUMER))
		return -ENOMEM;
	if (!dev_get_drvdata(dev->parent))
		return -ENODEV;
	test = devm_kzalloc(dev, sizeof(*test), GFP_KERNEL);
	if (!test)
		return -ENOMEM;
	test->dev = dev;
	mutex_init(&test->lock);
	spin_lock_init(&test->rx_lock);
	init_completion(&test->reply);
	INIT_WORK(&test->initialize_work, qcmb_initialize);
	auxiliary_set_drvdata(adev, test);
	test->client = devm_pmic_glink_client_alloc(dev, QCMB_OWNER,
						  qcmb_receive, qcmb_service, test);
	if (IS_ERR(test->client))
		return PTR_ERR(test->client);
	ret = devm_add_action_or_reset(dev, qcmb_stop, test);
	if (ret)
		return ret;
	pmic_glink_client_register(test->client);
	test->reboot.notifier_call = qcmb_reboot;
	ret = devm_register_reboot_notifier(dev, &test->reboot);
	if (ret)
		return ret;
	test->pm.notifier_call = qcmb_pm;
	ret = register_pm_notifier(&test->pm);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(dev, qcmb_unregister_pm, test);
	if (ret)
		return ret;
	dev_info(dev, "Poweroff mailbox preparation enabled (flags clear)\n");
	if (suspend_disabled)
		dev_info(dev, "Suspend mailbox preparation disabled; poweroff unchanged\n");
	else
		dev_info(dev, "Suspend mailbox preparation enabled (reasons 2/1, flags clear)\n");
	return 0;
}

static const struct auxiliary_device_id qcmb_id_table[] = {
	{ .name = "pmic_glink.shutdown" },
	{}
};
MODULE_DEVICE_TABLE(auxiliary, qcmb_id_table);

static struct auxiliary_driver qcmb_driver = {
	.name = "pmic_glink_shutdown",
	.probe = qcmb_probe,
	.id_table = qcmb_id_table,
};
module_auxiliary_driver(qcmb_driver);

MODULE_DESCRIPTION("Qualcomm PMIC GLINK suspend and shutdown preparation");
MODULE_LICENSE("GPL");
