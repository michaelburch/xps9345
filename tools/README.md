# Tools

Userspace helpers for inspecting X1E80100 sleep residency and AOSS BCM vote
tables.

## `xps-rpmh-stats.sh` (requires `xps-rpmh-xo.sh` in the same directory)

Captures `/sys/kernel/debug/qcom_stats/*` (`apss`, `adsp`, `cdsp`, `aosd`,
`cxsd`, `ddr`), `ddr_stats`, and battery energy deltas across a manual suspend
cycle, then prints residency percentages and average power.

```sh
sudo ./xps-rpmh-stats.sh [TAG] [-s SECS] [--stats-only] [--usb-wakeup-off] [--no-freqsync]
```

- `--stats-only`: read `qcom_stats` / `ddr_stats` / battery only (no ftrace or dynamic debug)
- `--usb-wakeup-off`: temporarily disable wakeup on `a400000.usb`, `a600000.usb`, `a800000.usb`

## `xps-vt-drv0.c`

Read-only userspace dump of TrustZone's row (`DRV0`, `0x0ba00000`) and Linux's
row (`DRV2`, `0x0ba20000`) in the AOSS BCM vote table via `/dev/mem` and
`/sys/kernel/debug/cmd-db`. **EL2 only** (Gunyah does not map `0x0ba00000` at
EL1).

```sh
gcc -O2 -Wall -Wextra -o xps-vt-drv0 xps-vt-drv0.c
sudo ./xps-vt-drv0 --canary vt.log   # read DRV2 ACV canary only
sudo ./xps-vt-drv0 --all vt.log      # read canary + all DRV0 BCMs
```

*(Note: checks DMI for `XPS 13 9345` / BIOS `2.14.0` by default as a safety guard; adjust the DMI check in `main()` for other X1E boards at EL2.)*

## `xps-pm-snapshot.sh`

Snapshots runtime PM states, `pm_genpd_summary`, wakeup sources, and
`qcom_stats`.

```sh
sudo ./xps-pm-snapshot.sh [OUTFILE]
```
