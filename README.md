# cmpunlocker

Unlock tool for the NVIDIA CMP 170HX (GA100) mining card. Restores full SM compute throughput and unlocked HBM2e memory geometry that are restricted in firmware/OTP configuration.

Targets **nvidia-open driver 610.43.0x** on Linux. cmpunlocker does **not** install the full NVIDIA userspace package — it patches and installs open kernel modules only.

**[Join our Discord community](https://discord.gg/CdHSakKSFv)** for support and discussions.

---

## Background

The CMP 170HX is a physically complete GA100 die (same silicon as the A100) with compute and memory artificially limited. This tool applies an in-driver unlock path (SEC2 Booter PLM open + host SS0/SS1/CFG1/LMR writes + FB/PMA adjustments) that runs automatically every time the patched modules boot GSP for PCI ID `0x20C2`.

Card size selects the memory geometry:

| Physical card | Unlock geometry | CFG1 | LMR |
|---|---|---|---|
| **8 GB** | **64 GB** | `0x02779000` | `0x0000020B` |
| **10 GB** | **40 GB** | `0x02669000` | `0x0000028A` |

---

## Proof of Concept

Below are memory and performance results after applying the unlock:

### Memory Unlock Results

<img alt="memory unlock" src="https://github.com/user-attachments/assets/ae062bd8-e3a7-4e73-b9a4-fbcde53f3c7b" width="100%" style="max-width: 900px;" />

### Performance Benchmarks ([OpenCL-Benchmark](https://github.com/ProjectPhysX/OpenCL-Benchmark))

<img alt="performance benchmarks" src="https://github.com/user-attachments/assets/2501506d-420f-4014-9574-b1bd0290eb60" width="100%" style="max-width: 900px;" />

---

## Requirements

- Linux (x86-64)
- Root access
- NVIDIA CMP 170HX
- **nvidia-open 610.43.0x already installed** (libs + firmware)
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads matching stock `open-gpu-kernel-modules` sources)
- Python 3 (used at build time to select 8GB/10GB geometry)

---

## Install

One command. Auto-detects 8GB vs 10GB from stock `nvidia-smi` memory, then builds patched open kernel modules into `/lib/modules/$(uname -r)/updates/cmpunlocker/`.

```bash
sudo ./install.sh
```

Force a profile if detection is wrong or `nvidia-smi` is unavailable:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

Then perform a **cold reboot** (full power off, then boot) if modules did not hot-reload cleanly, or if memory still shows the stock size.

---

## Verify

```bash
nvidia-smi
# 8GB card:  expect ~65536 MiB
# 10GB card: expect ~40960 MiB

nvidia-smi --query-gpu=memory.total,clocks.max.sm --format=csv

sudo dmesg | grep SEC2_DEBUG
# Expected: PLMs opening to 0xffffffff, CFG1/LMR/SS0/SS1 writes, late PMA

cat /lib/modules/$(uname -r)/updates/cmpunlocker/card_profile
# 8gb or 10gb
```

Booter status codes such as `0x31` / `0xffff` during the early PLM Booter passes can appear and are often harmless if the final boot succeeds.

---

## What Gets Unlocked

| Feature | Status |
|---|---|
| Full SM compute throughput (SS0/SS1) | Working ✓ |
| Memory geometry (64GB on 8GB cards, 40GB on 10GB cards) | Working ✓ |
| Persistence across reboot (patched modules) | Working ✓ |

---

## Uninstall

Restore stock module loading:

```bash
sudo ./remove.sh --yes
```

This removes `/lib/modules/*/updates/cmpunlocker/`, runs `depmod`, and attempts to reload stock NVIDIA modules. Reboot if the GPU does not come back cleanly.

---

## Support & Community

Having issues? Need help? Join our [Discord community](https://discord.gg/CdHSakKSFv) to discuss with other users and get support.
