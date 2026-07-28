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

### Early-boot PCIe Gen2 retraining

The Gen2 capability opened by `0007-pcie-gen2.patch` is transient during GSP
bootstrap. The installer therefore enables `cmp-gen2-early.service`, which asks
the CMP endpoint and its dynamically detected upstream bridge for Gen2 every
50 ms during early boot. It stops as soon as the negotiated `LnkSta` reaches
Gen2. The installer only enables the service; it never retrains the active link
in the current desktop session.

To install the memory/compute patches without arming early PCIe retraining:

```bash
sudo ./install.sh --no-gen2-service
```

The standalone service controls leave the patched NVIDIA driver untouched:

```bash
sudo ./tools/cmp-gen2-service.sh install
sudo ./tools/cmp-gen2-service.sh verify
sudo ./tools/cmp-gen2-service.sh remove
```

If a machine does not finish booting during first-time testing, add
`systemd.mask=cmp-gen2-early.service` temporarily to the kernel command line.

See [the 10 GB `10de:2082` validation](docs/gen2-10gb-2082-validation.md) for
the tested hardware/software configuration, boot timing, bandwidth results,
and reporting differences from the published 8 GB result.

#### Verified 10 GB (`10de:2082`) result

The early service has been validated on one 10 GB card with driver
`610.43.02`, VBIOS `92.00.66.00.02`, and an Intel Xeon E5 v4 host:

| Measurement | Gen1 x4 | Gen2 x4 |
|---|---:|---:|
| PCI configuration `LnkSta` | `0x1041` | `0x1042` |
| sysfs `current_link_speed` | 2.5 GT/s | 5.0 GT/s |
| Pinned H2D bandwidth | ~0.82 GB/s | 1.633 GB/s |
| Pinned D2H bandwidth | ~0.84 GB/s | 1.679 GB/s |
| Unlocked memory | 40960 MiB | 40960 MiB |

On this 10 GB configuration, NVML/`nvidia-smi` continued to report PCIe Gen1
and sysfs `max_link_speed` returned to 2.5 GT/s after the transient window
closed. Those fields were stale capability reports: `LnkSta=0x1042`, sysfs
`current_link_speed=5.0 GT/s`, and the doubled host-transfer bandwidth
confirmed that the link remained negotiated at Gen2. Do not use
`nvidia-smi` as the only Gen2 success criterion on `10de:2082`.

### IOMMU

The installer also enables the IOMMU in passthrough mode, appending `intel_iommu=on iommu=pt` (Intel) or `amd_iommu=on iommu=pt` (AMD) to the kernel command line via `/etc/default/grub` or `/etc/kernel/cmdline`, then regenerating the boot config. Conflicting `iommu=` / `*_iommu=` entries are replaced, the original file is backed up to `*.cmpunlocker.bak`, and `remove.sh` restores it.

This takes effect on the next reboot, and still requires VT-d / AMD-Vi to be enabled in BIOS/UEFI. To leave the kernel command line untouched:

```bash
sudo ./install.sh --no-iommu
```

Then perform a **cold reboot** (full power off, then boot) if modules did not hot-reload cleanly, or if memory still shows the stock size.

---

## Verify

```bash
nvidia-smi
# 8GB card:  expect ~65536 MiB
# 10GB card: expect ~40960 MiB

nvidia-smi --query-gpu=memory.total,pcie.link.gen.current,pcie.link.gen.max,clocks.max.sm --format=csv
# The 8GB variant may report current=2. On the tested 10GB/2082 card, NVML
# continued to report current=1/max=1 after a successful Gen2 retrain.

sudo lspci -d 10de:20c2 -vv | grep -E 'LnkCap:|LnkSta:'  # 8GB
sudo lspci -d 10de:2082 -vv | grep -E 'LnkCap:|LnkSta:'  # 10GB
# Expect LnkSta: Speed 5GT/s (not 2.5GT/s)

sudo ./tools/cmp-gen2-service.sh verify
sudo dmesg | grep SEC2_DEBUG
# Expected: PLMs opening to 0xffffffff, CFG1/LMR/SS0/SS1 writes, late PMA
cat /lib/modules/$(uname -r)/updates/cmpunlocker/card_profile
# 8gb or 10gb
```

## What Gets Unlocked

| Feature | Status |
|---|---|
| Full SM compute throughput (SS0/SS1) | Working ✓ |
| Memory geometry (64GB on 8GB cards, 40GB on 10GB cards) | Working ✓ |
| PCIe Gen2 link (`LnkSta` at `5GT/s`) | Early-boot retrain required |
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
