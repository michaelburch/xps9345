# Linux on the Dell XPS 13 9345 (X1E80100)

Personal kernel tree for running Linux on the Dell XPS 13 9345 (Snapdragon X
Elite). I really enjoy this laptop and maintain these branches to make it the
best experience possible for my daily use, sharing patches here in case they are
useful to others.

Patches in this tree are a mix of hand-written code, community backports, and
AI-generated/assisted work, tested on hardware and reviewed with Sashiko.

## Upstream & Base Trees

Originally forked from [`linux-msm/laptops-kernel`](https://github.com/linux-msm/laptops-kernel)
(`qcom-laptops` and `qcom-laptops-v7.2`).

## Branches

- **[xps/v7.3.0](https://github.com/michaelburch/xps9345/tree/xps/v7.3.0)** - upstream Linux v7.3 with Qualcomm laptop support and XPS-specific patches.
- **`main`** - documentation and userspace tools.

Kernel version branches are rolling and may be force-updated.

## Tools

[`tools/`](tools/) on `main` holds userspace scripts and utilities for measuring
`qcom_stats` sleep residency (`xps-rpmh-stats.sh`, standalone), taking PM
snapshots, and reading the AOSS BCM vote table at EL2 (`xps-vt-drv0.c`).
See [`tools/README.md`](tools/README.md).

