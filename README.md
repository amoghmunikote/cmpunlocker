# cmpunlocker

Unlock tool for the NVIDIA CMP 170HX (GA100) mining card. Restores full SM compute throughput and unlocked HBM2e memory geometry that are restricted in firmware/OTP configuration.

Targets **nvidia-open driver 610.43.0x** on Linux. cmpunlocker does **not** install the full NVIDIA userspace package — it patches and installs open kernel modules only.

Supports **one or more** CMP 170HX GPUs in a single install, including **mixed 8GB + 10GB** systems. Unlock geometry is chosen per GPU from PCI device ID at GSP boot.

**[Join our Discord community](https://discord.gg/CdHSakKSFv)** for support and discussions.

---

## Background

The CMP 170HX is a physically complete GA100 die (same silicon as the A100) with compute and memory artificially limited. This tool applies an in-driver unlock path (SEC2 Booter PLM open + host SS0/SS1/CFG1/LMR writes + FB/PMA adjustments) that runs automatically every time the patched modules boot GSP for each matching GPU (`0x20C2` / `0x2082`).

Card size selects the memory geometry:

| Physical card | PCI ID | Unlock geometry | CFG1 | LMR |
|---|---|---|---|---|
| **8 GB** | `0x20C2` | **64 GB** | `0x02779000` | `0x0000020B` |
| **10 GB** | `0x2082` | **40 GB** | `0x02669000` | `0x0000028A` |

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
- One or more NVIDIA CMP 170HX GPUs (`10de:20c2` and/or `10de:2082`)
- **nvidia-open 610.43.0x already installed** (libs + firmware)
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads matching stock `open-gpu-kernel-modules` sources)
- Python 3 (used at build time)

---

## Install

One command. Enumerates all CMP 170HX GPUs, classifies each by PCI ID (8GB vs 10GB), then builds patched open kernel modules into `/lib/modules/$(uname -r)/updates/cmpunlocker/`.

```bash
sudo ./install.sh
```

Optional metadata override (geometry still follows each GPU’s PCI ID at runtime):

```bash
sudo ./install.sh --profile=8gb
sudo ./install.sh --profile=10gb
```

Then perform a **cold reboot** (full power off, then boot) if modules did not hot-reload cleanly, or if any GPU still shows stock memory.

Install metadata written under `/lib/modules/$(uname -r)/updates/cmpunlocker/`:

| File | Contents |
|---|---|
| `card_profile` | `8gb`, `10gb`, or `mixed` |
| `unlock_geometry` | `64GB`, `40GB`, or `mixed` |
| `gpu_inventory` | One line per GPU: `BDF devid profile expected_mib` |

---

## Verify

After reboot, verify **every** unlockable GPU:

```bash
sudo ./verify.sh
```

`verify.sh` checks each card’s `nvidia-smi` memory by PCI bus ID against the expected unlocked size (~65536 MiB for 8GB / ~40960 MiB for 10GB) and reports `SEC2_DEBUG` dmesg lines when present.

Manual checks:

```bash
nvidia-smi
# Each 8GB card:  expect ~65536 MiB
# Each 10GB card: expect ~40960 MiB

nvidia-smi --query-gpu=pci.bus_id,memory.total,clocks.max.sm --format=csv

sudo dmesg | grep SEC2_DEBUG
# Expected: PLMs opening to 0xffffffff, CFG1/LMR/SS0/SS1 writes, late PMA

cat /lib/modules/$(uname -r)/updates/cmpunlocker/gpu_inventory
cat /lib/modules/$(uname -r)/updates/cmpunlocker/card_profile
```

Booter status codes such as `0x31` / `0xffff` during the early PLM Booter passes can appear and are often harmless if the final boot succeeds.

---

## What Gets Unlocked

| Feature | Status |
|---|---|
| Full SM compute throughput (SS0/SS1) | Working ✓ |
| Memory geometry (64GB on 8GB cards, 40GB on 10GB cards) | Working ✓ |
| Multi-GPU / mixed 8GB+10GB in one install | Working ✓ |
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
