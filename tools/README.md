# Tools

Userspace tools for the Dell XPS 13 9345. They are independent of the kernel
checkout. Requirements include Bash, Python3, GNU awk/coreutils, util-linux
(`flock`), systemd and mounted debugfs. Root is required for capture, not help
or the offline tests. These tools do not install kernels or firmware.

## Standalone Sleep Residency

`xps-rpmh-stats.sh` samples Qualcomm sleep counters, CPU idle/domain counters,
wakeup sources and battery energy before and after suspend. It is standalone:
there is no companion XO helper, tracing setup, dynamic-debug setup or clock
snapshot. `--stats-only` remains accepted as a compatibility no-op.

From this repository's root:

```sh
bash tools/xps-rpmh-stats.sh --help
sudo bash tools/xps-rpmh-stats.sh baseline -s 600
```

**The default command requests system suspend.** Wake the machine yourself
after the desired interval. `-s` is a target duration, not a wake timer or
a delay after resume. The tool holds a lock to exclude concurrent captures.

To suspend by closing the lid instead:

```sh
sudo bash tools/xps-rpmh-stats.sh lid-test --manual --power -s 3600
```

Leave the terminal running. The tool records the post-suspend snapshot after
wake. Ctrl-C cancels capture; waiting times out after two awake hours.

Options and side effects:

- `--manual` waits for your suspend instead of requesting one.
- `--power` installs a temporary systemd sleep hook for entry/exit battery
	samples, then removes it on normal exit or handled cancellation. A crash
	or power loss can leave the hook behind. Charging samples are rejected.
- `--usb-wakeup-off` saves, disables and restores controller wake permissions.
	USB devices cannot wake this test. Missing controls abort before suspend;
	recovery after a crash/power loss is not guaranteed.
- `--smp2p-wake` is an advanced experiment: it disables ADSP/CDSP recovery and
	enables SMP2P wake. Those changes deliberately persist until reboot, even
	after cancellation; automatic recovery is not restored. Do not use it to
	validate kernel defaults, and do not use it after a failed suspend without
	a cold boot.
- `--no-freqsync` skips the pre-suspend `ddr_stats` read. On kernels where
	that read sends a firmware frequency-sync request, the post-read can still
	send one. DDR LPM is then reported since boot, not purely for the interval.
- `--usb-wake-trace` has been removed and is rejected.

Logs go to `logs/` beside `tools/`, or the directory specified by `OUTDIR`.
Kernel messages are saved separately with a `.kernel.log` suffix. Percentages
label their denominator: `%wall` includes awake time; `*_RESIDENCY` uses the
measured suspended interval. Battery-window power includes awake overhead.
Use matched battery/peripheral conditions and long intervals for power
comparisons; short gauge-quantized measurements are not reliable benchmarks.
The tool does not disable tracing started by other programs.

Offline tests use temporary fixtures and mocked suspend/PM commands:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p test_rpmh_stats.py
```

## PM Snapshot

```sh
sudo bash tools/xps-pm-snapshot.sh battery-idle
```

The argument is a tag, not an output filename. Output defaults to `./logs/`
under the current directory; `OUTDIR` overrides it. This broad diagnostic
includes clock summaries and system identifiers. Reading clock summaries
can resume providers and perturb idle state, so do not treat it as a passive
power measurement.

## Advanced EL2 Vote-Table Reader

`xps-vt-drv0.c` reads AOSS BCM vote-table rows through `/dev/mem`. It is not
required for ordinary residency testing. A read can fault or reset a machine
with a different memory-access configuration. **Never run it at EL1.**
Independently verify the boot exception level; `/dev/kvm` alone is not proof.
The XPS 13 9345 / BIOS 2.14.0 checks are restrictions, not a portability claim.
Do not bypass them for other boards or firmware.

Compile without accessing hardware:

```sh
cc -O2 -Wall -Wextra -o /var/tmp/xps-vt-drv0 tools/xps-vt-drv0.c
```

For an independently verified compatible EL2 boot, explicit invocation of
`--canary LOGFILE` reads the DRV2 canary; `--all LOGFILE` additionally reads
DRV0 BCM entries. Logfiles must not already exist. Do not generalize successful
reads to other AOSS registers, and inspect captured identifiers before sharing.
