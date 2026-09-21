// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026, Aleksandrs Vinarskis <alex@vinarskis.com>
 */

#include <linux/array_size.h>
#include <linux/bitops.h>
#include <linux/container_of.h>
#include <linux/dev_printk.h>
#include <linux/device.h>
#include <linux/devm-helpers.h>
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/iio/consumer.h>
#include <linux/interrupt.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/overflow.h>
#include <linux/pm.h>
#include <linux/types.h>
#include <linux/unaligned.h>
#include <linux/units.h>
#include <linux/workqueue.h>

/*
 * Single-byte registers, addressed as a leading I2C command byte followed by
 * a repeated-start read, matching ECR1()/ECW1() in the Dell DSDT.
 */
#define DELL_XPS_EC_REG_STATUS		0x00
#define DELL_XPS_EC_STATUS_LID_OPEN	BIT(4)
#define DELL_XPS_EC_REG_EVENT_LOW	0x07
#define DELL_XPS_EC_REG_EVENT_HIGH	0x0b
#define DELL_XPS_EC_REG_QUEUE_LEN	0x2b
#define DELL_XPS_EC_REG_QUEUE_DATA	0x2c
#define DELL_XPS_EC_REG_EVENT_STATUS	0x2e
#define DELL_XPS_EC_REG_THERMAL_MODE	0x80

#define DELL_XPS_EC_SUSPEND_CMD		0xb9
#define DELL_XPS_EC_SUSPEND_MSG_LEN	65

#define DELL_XPS_EC_TEMP_CMD0		0xfb
#define DELL_XPS_EC_TEMP_CMD1		0x20
#define DELL_XPS_EC_TEMP_CMD3		0x02
#define DELL_XPS_EC_TEMP_MSG_LEN	6
#define DELL_XPS_EC_TEMP_POLL_JIFFIES	msecs_to_jiffies(100)

/*
 * Event word, assembled as (0x0b | 0x0c << 8) << 16 | (0x07 | 0x08 << 8),
 * matching NEVT() in the DSDT. Every other branch there is an empty stub.
 */
#define DELL_XPS_EC_EVT_LID		BIT(2)
#define DELL_XPS_EC_EVT_POWER		BIT(3)
#define DELL_XPS_EC_EVT_QUEUE		BIT(11)
#define DELL_XPS_EC_EVT_STATUS		BIT(15)
#define DELL_XPS_EC_EVT_THERMAL_MODE	BIT(28)
#define DELL_XPS_EC_EVT_HANDLED		(DELL_XPS_EC_EVT_LID | \
					 DELL_XPS_EC_EVT_POWER | \
					 DELL_XPS_EC_EVT_QUEUE | \
					 DELL_XPS_EC_EVT_STATUS | \
					 DELL_XPS_EC_EVT_THERMAL_MODE)

#define DELL_XPS_EC_READ_LEN		64
#define DELL_XPS_EC_QUEUE_MAX		32
#define DELL_XPS_EC_IRQ_LIMIT		32
#define DELL_XPS_EC_IRQ_RETRIES		3
#define DELL_XPS_EC_IRQ_RETRY_JIFFIES	msecs_to_jiffies(1000)

/*
 * Mapping between IIO channel name (as per schematics) and EC command byte.
 */
struct dell_xps_ec_therm {
	const char *name;
	u8 cmd;
};

struct dell_xps_ec_data {
	const struct dell_xps_ec_therm *therms;
	unsigned int num_therms;
	const u8 *profile;
	size_t profile_len;
};

/*
 * Format:
 * - header/unknown (2 bytes)
 * - per-thermistor entries (3 bytes): thermistor_id, param1, param2
 */
static const u8 dell_xps13_9345_thermistor_profile[] = {
	0xff, 0x54,
	0x01, 0x00, 0x2b,	/* sys_therm0 */
	0x02, 0x44, 0x2a,	/* sys_therm1 */
	0x03, 0x44, 0x2b,	/* sys_therm2 */
	0x04, 0x44, 0x28,	/* sys_therm3 */
	0x05, 0x55, 0x2a,	/* sys_therm4 */
	0x06, 0x44, 0x26,	/* sys_therm5 */
	0x07, 0x44, 0x2b,	/* sys_therm6 */
};

static const struct dell_xps_ec_therm dell_xps13_9345_therms[] = {
	/* TODO: 0x01 is sent only occasionally, likely TZ98 or TZ4. */
	{ "sys_therm0", 0x02 },
	{ "sys_therm1", 0x03 },
	{ "sys_therm2", 0x04 },
	{ "sys_therm3", 0x05 },
	{ "sys_therm4", 0x06 },
	{ "sys_therm5", 0x07 },
	{ "sys_therm6", 0x08 },
};

static const struct dell_xps_ec_data dell_xps13_9345_data = {
	.therms = dell_xps13_9345_therms,
	.num_therms = ARRAY_SIZE(dell_xps13_9345_therms),
	.profile = dell_xps13_9345_thermistor_profile,
	.profile_len = sizeof(dell_xps13_9345_thermistor_profile),
};

struct dell_xps_ec {
	struct device *dev;
	struct i2c_client *client;
	const struct dell_xps_ec_data *data;
	struct delayed_work temp_work;
	struct delayed_work irq_work;
	/* Serialises every transfer to the EC. */
	struct mutex lock;
	unsigned long irq_quiet_until;
	unsigned int irq_count;
	unsigned int irq_faults;
	bool irq_masked;
	u8 thermal_mode;
	unsigned int num_therms;
	struct iio_channel *therm_channels[] __counted_by(num_therms);
};

static int dell_xps_ec_write(struct dell_xps_ec *ec, const u8 *buf, size_t len)
{
	int ret;

	mutex_lock(&ec->lock);
	ret = i2c_master_send(ec->client, buf, len);
	mutex_unlock(&ec->lock);

	if (ret < 0)
		return ret;

	return ret == len ? 0 : -EIO;
}

static int dell_xps_ec_read_locked(struct dell_xps_ec *ec, u8 command,
				   u8 *value)
{
	u8 payload[DELL_XPS_EC_READ_LEN];
	struct i2c_msg messages[] = {
		{
			.addr = ec->client->addr,
			.len = sizeof(command),
			.buf = &command,
		}, {
			.addr = ec->client->addr,
			.flags = I2C_M_RD,
			.len = sizeof(payload),
			.buf = payload,
		},
	};
	int ret;

	lockdep_assert_held(&ec->lock);

	ret = i2c_transfer(ec->client->adapter, messages, ARRAY_SIZE(messages));
	if (ret != ARRAY_SIZE(messages))
		return ret < 0 ? ret : -EIO;

	*value = payload[0];
	return 0;
}

static int dell_xps_ec_suspend_cmd(struct dell_xps_ec *ec, bool suspend)
{
	u8 buf[DELL_XPS_EC_SUSPEND_MSG_LEN] = {};

	buf[0] = DELL_XPS_EC_SUSPEND_CMD;
	buf[1] = suspend ? 0x01 : 0x00;
	/* bytes 2..64 remain zero */

	return dell_xps_ec_write(ec, buf, sizeof(buf));
}

static int dell_xps_ec_send_temp(struct dell_xps_ec *ec, u8 cmd_byte,
				 int milli_celsius)
{
	u8 buf[DELL_XPS_EC_TEMP_MSG_LEN];
	u16 deci_celsius;

	deci_celsius = milli_celsius / MILLIDEGREE_PER_DECIDEGREE;

	buf[0] = DELL_XPS_EC_TEMP_CMD0;
	buf[1] = DELL_XPS_EC_TEMP_CMD1;
	buf[2] = cmd_byte;
	buf[3] = DELL_XPS_EC_TEMP_CMD3;
	put_unaligned_le16(deci_celsius, &buf[4]);

	return dell_xps_ec_write(ec, buf, sizeof(buf));
}

static void dell_xps_ec_temp_work_fn(struct work_struct *work)
{
	struct dell_xps_ec *ec = container_of(work, struct dell_xps_ec,
					      temp_work.work);
	const struct dell_xps_ec_therm *therms = ec->data->therms;
	int val, ret;
	unsigned int i;

	for (i = 0; i < ec->num_therms; i++) {
		ret = iio_read_channel_processed(ec->therm_channels[i], &val);
		if (ret < 0) {
			dev_err_ratelimited(ec->dev,
					    "Failed to read thermistor %s: %d\n",
					    therms[i].name, ret);
			continue;
		}

		ret = dell_xps_ec_send_temp(ec, therms[i].cmd, val);
		if (ret < 0) {
			dev_err_ratelimited(ec->dev,
					    "Failed to send temp for %s: %d\n",
					    therms[i].name, ret);
		}
	}

	schedule_delayed_work(&ec->temp_work, DELL_XPS_EC_TEMP_POLL_JIFFIES);
}

/* Callers must hold ec->lock; safe to call from the threaded IRQ handler. */
static void dell_xps_ec_mask_irq(struct dell_xps_ec *ec)
{
	if (ec->irq_masked)
		return;

	disable_irq_nosync(ec->client->irq);
	ec->irq_masked = true;
}

static void dell_xps_ec_unmask_irq(struct dell_xps_ec *ec)
{
	if (!ec->irq_masked)
		return;

	ec->irq_masked = false;
	ec->irq_count = 0;
	ec->irq_quiet_until = jiffies + DELL_XPS_EC_TEMP_POLL_JIFFIES;
	enable_irq(ec->client->irq);
}

static void dell_xps_ec_irq_work_fn(struct work_struct *work)
{
	struct dell_xps_ec *ec = container_of(work, struct dell_xps_ec,
					      irq_work.work);

	mutex_lock(&ec->lock);
	dell_xps_ec_unmask_irq(ec);
	mutex_unlock(&ec->lock);
}

/*
 * Drain the event queue the DSDT reads in EC0A(): a length byte at 0x2b
 * followed by that many reads of 0x2c.
 */
static int dell_xps_ec_drain_queue(struct dell_xps_ec *ec)
{
	unsigned int i;
	u8 len, value;
	int ret;

	ret = dell_xps_ec_read_locked(ec, DELL_XPS_EC_REG_QUEUE_LEN, &len);
	if (ret)
		return ret;

	if (len > DELL_XPS_EC_QUEUE_MAX) {
		dev_warn_ratelimited(ec->dev, "EC queue length %u clamped\n",
				     len);
		len = DELL_XPS_EC_QUEUE_MAX;
	}

	for (i = 0; i < len; i++) {
		ret = dell_xps_ec_read_locked(ec, DELL_XPS_EC_REG_QUEUE_DATA,
					      &value);
		if (ret)
			return ret;

		dev_dbg(ec->dev, "EC queue byte %u: %#04x\n", i, value);
	}

	return 0;
}

static int dell_xps_ec_service_events(struct dell_xps_ec *ec, u32 events)
{
	u32 unhandled;
	u8 value;
	int ret;

	lockdep_assert_held(&ec->lock);

	if (events & DELL_XPS_EC_EVT_LID) {
		/* The lid switch itself stays owned by the gpio-keys node. */
		ret = dell_xps_ec_read_locked(ec, DELL_XPS_EC_REG_STATUS,
					      &value);
		if (ret)
			return ret;

		dev_dbg(ec->dev, "EC lid %s\n",
			value & DELL_XPS_EC_STATUS_LID_OPEN ? "open" : "closed");
	}

	if (events & DELL_XPS_EC_EVT_QUEUE) {
		ret = dell_xps_ec_drain_queue(ec);
		if (ret)
			return ret;
	}

	if (events & DELL_XPS_EC_EVT_THERMAL_MODE) {
		ret = dell_xps_ec_read_locked(ec, DELL_XPS_EC_REG_THERMAL_MODE,
					      &value);
		if (ret)
			return ret;

		/*
		 * ECTT() only stores a thermal-table index for ACPI trip
		 * points; the EC keeps applying its own fan curve either way.
		 */
		if (value != ec->thermal_mode) {
			ec->thermal_mode = value;
			dev_dbg(ec->dev, "EC thermal mode %#04x\n", value);
		}
	}

	if (events & DELL_XPS_EC_EVT_STATUS) {
		ret = dell_xps_ec_read_locked(ec, DELL_XPS_EC_REG_EVENT_STATUS,
					      &value);
		if (ret)
			return ret;

		dev_dbg(ec->dev, "EC status %#04x\n", value);
	}

	if (events & DELL_XPS_EC_EVT_POWER) {
		/* PWCH() reads an ACPI external with no register behind it. */
		dev_dbg(ec->dev, "EC power source change\n");
	}

	unhandled = events & ~DELL_XPS_EC_EVT_HANDLED;
	if (unhandled)
		dev_dbg(ec->dev, "EC events without a handler: %#010x\n",
			unhandled);

	return 0;
}

static irqreturn_t dell_xps_ec_irq_handler(int irq, void *data)
{
	static const u8 event_commands[] = {
		DELL_XPS_EC_REG_EVENT_LOW, DELL_XPS_EC_REG_EVENT_LOW + 1,
		DELL_XPS_EC_REG_EVENT_HIGH, DELL_XPS_EC_REG_EVENT_HIGH + 1,
	};
	u8 event_bytes[ARRAY_SIZE(event_commands)];
	struct dell_xps_ec *ec = data;
	unsigned int i;
	u32 events;
	int ret;

	mutex_lock(&ec->lock);

	if (time_after_eq(jiffies, ec->irq_quiet_until)) {
		ec->irq_count = 0;
		ec->irq_faults = 0;
	}
	if (++ec->irq_count > DELL_XPS_EC_IRQ_LIMIT) {
		ret = -EOVERFLOW;
		goto fault;
	}

	for (i = 0; i < ARRAY_SIZE(event_commands); i++) {
		ret = dell_xps_ec_read_locked(ec, event_commands[i],
					      &event_bytes[i]);
		if (ret)
			goto fault;
	}

	events = get_unaligned_le32(event_bytes);
	dev_dbg(ec->dev, "EC events: %#010x\n", events);

	ret = dell_xps_ec_service_events(ec, events);
	if (ret)
		goto fault;

	ec->irq_quiet_until = jiffies + DELL_XPS_EC_TEMP_POLL_JIFFIES;
	mutex_unlock(&ec->lock);

	return IRQ_HANDLED;

fault:
	dell_xps_ec_mask_irq(ec);
	if (++ec->irq_faults > DELL_XPS_EC_IRQ_RETRIES)
		dev_err(ec->dev,
			"EC event service failed (%d), IRQ left masked\n", ret);
	else
		schedule_delayed_work(&ec->irq_work,
				      DELL_XPS_EC_IRQ_RETRY_JIFFIES);
	mutex_unlock(&ec->lock);

	return IRQ_HANDLED;
}

static int dell_xps_ec_probe(struct i2c_client *client)
{
	const struct dell_xps_ec_data *data;
	struct device *dev = &client->dev;
	struct dell_xps_ec *ec;
	unsigned int i;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -EOPNOTSUPP;

	if (client->irq <= 0)
		return dev_err_probe(dev, -EINVAL, "Missing EC interrupt\n");

	data = i2c_get_match_data(client);
	if (!data)
		return dev_err_probe(dev, -ENODEV, "No match data\n");

	ec = devm_kzalloc(dev, struct_size(ec, therm_channels, data->num_therms),
			  GFP_KERNEL);
	if (!ec)
		return -ENOMEM;

	ec->dev = dev;
	ec->client = client;
	ec->data = data;
	ec->num_therms = data->num_therms;
	ec->irq_quiet_until = jiffies;
	mutex_init(&ec->lock);
	i2c_set_clientdata(client, ec);

	/* Get IIO channels for thermistors */
	for (i = 0; i < ec->num_therms; i++) {
		ec->therm_channels[i] =
			devm_iio_channel_get(dev, data->therms[i].name);
		if (IS_ERR(ec->therm_channels[i])) {
			ret = PTR_ERR(ec->therm_channels[i]);
			return dev_err_probe(dev, ret,
					     "Thermistor %s unavailable\n",
					     data->therms[i].name);
		}
	}

	/* Set default thermistor profile */
	ret = dell_xps_ec_write(ec, data->profile, data->profile_len);
	if (ret)
		return dev_err_probe(dev, ret, "Failed to set thermistor profile\n");

	ret = devm_delayed_work_autocancel(dev, &ec->irq_work,
					   dell_xps_ec_irq_work_fn);
	if (ret)
		return ret;

	/* Start periodic temperature reporting */
	ret = devm_delayed_work_autocancel(dev, &ec->temp_work,
					   dell_xps_ec_temp_work_fn);
	if (ret)
		return ret;
	schedule_delayed_work(&ec->temp_work, DELL_XPS_EC_TEMP_POLL_JIFFIES);
	dev_dbg(dev, "Started periodic temperature reporting to EC every %d ms\n",
		jiffies_to_msecs(DELL_XPS_EC_TEMP_POLL_JIFFIES));

	/* Request IRQ for EC events */
	ret = devm_request_threaded_irq(dev, client->irq, NULL,
					dell_xps_ec_irq_handler,
					IRQF_ONESHOT, dev_name(dev), ec);
	if (ret)
		return dev_err_probe(dev, ret, "Failed to request IRQ\n");

	return 0;
}

static void dell_xps_ec_quiesce(struct dell_xps_ec *ec)
{
	/* Cancel the recovery work first so it cannot unmask behind us. */
	cancel_delayed_work_sync(&ec->irq_work);

	mutex_lock(&ec->lock);
	dell_xps_ec_mask_irq(ec);
	mutex_unlock(&ec->lock);

	synchronize_irq(ec->client->irq);
	cancel_delayed_work_sync(&ec->temp_work);
}

static void dell_xps_ec_restart(struct dell_xps_ec *ec)
{
	mutex_lock(&ec->lock);
	ec->irq_faults = 0;
	dell_xps_ec_unmask_irq(ec);
	mutex_unlock(&ec->lock);

	schedule_delayed_work(&ec->temp_work, DELL_XPS_EC_TEMP_POLL_JIFFIES);
}

/*
 * Notify EC of suspend
 *
 * This will:
 * - Cut power to display/trackpad/keyboard/touchrow, wake-up source still works.
 */
static int dell_xps_ec_suspend(struct device *dev)
{
	struct dell_xps_ec *ec = dev_get_drvdata(dev);
	int ret;

	dell_xps_ec_quiesce(ec);

	ret = dell_xps_ec_suspend_cmd(ec, true);
	if (ret)
		dell_xps_ec_restart(ec);

	return ret;
}

/*
 * Notify EC of resume
 *
 * This will undo the suspend actions. Without the resume signal, device would
 * wake up but be forced back into suspend by EC within seconds.
 */
static int dell_xps_ec_resume(struct device *dev)
{
	struct dell_xps_ec *ec = dev_get_drvdata(dev);
	int ret;

	ret = dell_xps_ec_suspend_cmd(ec, false);
	if (ret)
		return ret;

	dell_xps_ec_restart(ec);

	return 0;
}

static void dell_xps_ec_remove(struct i2c_client *client)
{
	dell_xps_ec_quiesce(i2c_get_clientdata(client));
}

static void dell_xps_ec_shutdown(struct i2c_client *client)
{
	dell_xps_ec_quiesce(i2c_get_clientdata(client));
}

static const struct of_device_id dell_xps_ec_of_match[] = {
	{ .compatible = "dell,xps13-9345-ec", .data = &dell_xps13_9345_data },
	{}
};
MODULE_DEVICE_TABLE(of, dell_xps_ec_of_match);

static const struct i2c_device_id dell_xps_ec_i2c_id[] = {
	{ "dell-xps-ec", (kernel_ulong_t)&dell_xps13_9345_data },
	{}
};
MODULE_DEVICE_TABLE(i2c, dell_xps_ec_i2c_id);

static const struct dev_pm_ops dell_xps_ec_pm_ops = {
	SYSTEM_SLEEP_PM_OPS(dell_xps_ec_suspend, dell_xps_ec_resume)
};

static struct i2c_driver dell_xps_ec_driver = {
	.driver = {
		.name = "dell-xps-ec",
		.of_match_table = dell_xps_ec_of_match,
		.pm = &dell_xps_ec_pm_ops,
	},
	.probe = dell_xps_ec_probe,
	.remove = dell_xps_ec_remove,
	.shutdown = dell_xps_ec_shutdown,
	.id_table = dell_xps_ec_i2c_id,
};
module_i2c_driver(dell_xps_ec_driver);

MODULE_AUTHOR("Aleksandrs Vinarskis <alex@vinarskis.com>");
MODULE_DESCRIPTION("Dell XPS 13 9345 Embedded Controller");
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS("IIO_CONSUMER");
