# Linux on the Dell XPS 13 9345 (X1E80100)

Personal kernel tree for running Linux on the Dell XPS 13 9345 (Snapdragon X
Elite). I really enjoy this laptop and maintain these branches to make it the
best experience possible for my daily use, sharing patches here in case they are
useful to others.

Patches in this tree are a mix of hand-written code, community backports, and
AI-generated/assisted work, tested on hardware and reviewed with Sashiko.

## Upstream & Base Trees

Forked from [`linux-msm/laptops-kernel`](https://github.com/linux-msm/laptops-kernel)
(`qcom-laptops` and `qcom-laptops-v7.2`).

## Branches

- **`qcom-laptops`** — [`linux-msm/laptops-kernel` `qcom-laptops`](https://github.com/linux-msm/laptops-kernel/tree/qcom-laptops) (7.3) + discrete TPM (`qcom.tz.tpm`) EL2 and SPI bus-release patches ([diff](https://github.com/michaelburch/xps9345/compare/65f4ae7320b8...qcom-laptops), [`.patch`](https://github.com/michaelburch/xps9345/compare/65f4ae7320b8...qcom-laptops.patch))
- **`qcom-laptops-v7.2`** — [`linux-msm/laptops-kernel` `qcom-laptops-v7.2`](https://github.com/linux-msm/laptops-kernel/tree/qcom-laptops-v7.2) + the same 5 TPM patches ([diff](https://github.com/michaelburch/xps9345/compare/62e0dd7464b6...qcom-laptops-v7.2), [`.patch`](https://github.com/michaelburch/xps9345/compare/62e0dd7464b6...qcom-laptops-v7.2.patch))

### Commits in the TPM series

Clears the TrustZone DRV0 `QUP1` + 76.8 MB/s DDR vote held by the discrete TPM's
SPI11 bus, which otherwise blocks DDR LPM and `cxsd`/`aosd` collapse on the
XPS 13 9345:

1. `firmware: qcom: scm: Supply the HLOS client ID for QSEE calls at EL2`
2. `firmware: qcom: scm: add TPM backend type query` *(Xilin Wu)*
3. `firmware: qcom: qseecom: register qcom.tz.tpm application` *(Xilin Wu)*
4. `tpm: add Qualcomm QSEE TPM transport driver` *(Xilin Wu)*
5. `tpm: qcom_qsee: Support discrete TPMs and release their SPI bus when idle`

### Required Kconfig

```ini
CONFIG_QCOM_TZMEM_MODE_SHMBRIDGE=y
# CONFIG_QCOM_TZMEM_MODE_GENERIC is not set
CONFIG_TCG_QCOM_TPM_QSEE=m
```

## Tools

[`tools/`](tools/) on `main` holds userspace scripts and utilities for measuring
`qcom_stats` sleep residency (`xps-rpmh-stats.sh`) and reading the AOSS BCM
vote table at EL2 (`xps-vt-drv0.c`). See [`tools/README.md`](tools/README.md).

