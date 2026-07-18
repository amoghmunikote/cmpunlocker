# cmpunlocker

Unlock tool for the NVIDIA CMP 170HX (GA100) mining card. Restores full SM
compute throughput and unlocked HBM2e memory geometry that are restricted in
firmware/OTP configuration.

Targets **nvidia-open driver 610.43.03** on Linux. cmpunlocker does **not**
install the full NVIDIA userspace package — it patches and installs open
kernel modules only.

> **AI agents:** before making changes, read `.ai/CONTEXT.md`.

---

## Background

The CMP 170HX is a physically complete GA100 die (same silicon as the A100)
with compute and memory artificially limited. This tool applies an in-driver
unlock path (SEC2 Booter PLM open + host SS0/SS1/CFG1/LMR writes + FB/PMA
adjustments) that runs automatically every time the patched modules boot GSP
for PCI ID `0x20C2`.

Card size selects the memory geometry:

| Physical card | Unlock geometry | CFG1 | LMR |
|---|---|---|---|
| **8 GB** | **64 GB** | `0x02779000` | `0x0000020B` |
| **10 GB** | **40 GB** | `0x02669000` | `0x0000028A` |

---

## Requirements

- Linux (x86-64)
- Root access
- NVIDIA CMP 170HX (`10de:20c2` preferred; `20b0` / `2082` detected but unlock is `0x20C2`-gated)
- **nvidia-open 610.43.03 already installed** (libs + firmware)
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads stock `open-gpu-kernel-modules` 610.43.03 sources)
- Python 3 (used at build time to select 8GB/10GB geometry)

---

## Install

One command. Auto-detects 8GB vs 10GB from stock `nvidia-smi` memory, then builds
patched open kernel modules into `/lib/modules/$(uname -r)/updates/cmpunlocker/`.

```bash
sudo ./install.sh
```

Force a profile if detection is wrong or `nvidia-smi` is unavailable:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

Then perform a **cold reboot** (full power off, then boot) if modules did not
hot-reload cleanly, or if memory still shows the stock size.

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

Booter status codes such as `0x31` / `0xffff` during the early PLM Booter
passes can appear and are often harmless if the final boot succeeds.

---

## What gets unlocked

| Feature | Status |
|---|---|
| Full SM compute throughput (SS0/SS1) | Working |
| Memory geometry (64GB on 8GB cards, 40GB on 10GB cards) | Working |
| Persistence across reboot (patched modules) | Working |
| PCIe Gen2 x4 | Platform-dependent (no separate Root-port patch) |
| ECC | Planned |
| NVLink | Planned |

---

## Persistence

No systemd daemon is required. Unlock logic is compiled into the patched
`nvidia` modules and re-applies on every GSP init for `0x20C2`.

---

## Uninstall

Restore stock module loading:

```bash
sudo ./remove.sh --yes
```

This removes `/lib/modules/*/updates/cmpunlocker/`, runs `depmod`, and
attempts to reload stock NVIDIA modules. Reboot if the GPU does not come back
cleanly.

---

## How it works

1. `install.sh` checks for a CMP 170HX and nvidia-open **610.43.03**
2. Selects **8gb** or **10gb** profile (auto or `--profile=`)
3. `driver/build.sh` downloads stock `open-gpu-kernel-modules` 610.43.03
4. Applies patches from `driver/patches/`, then rewrites CFG1/LMR/`fb_length` for the profile
5. Builds and installs modules to `updates/cmpunlocker/` (higher priority via depmod)
6. On load, `_kgspBootGspRm` opens PLMs via SEC2 Booter, writes SS0/SS1/CFG1/LMR,
   restores the stock GSP signature, boots GSP-RM, then extends FB length / PMA

---

## Troubleshooting

**`nvidia-smi` still shows stock memory (8192 / 10240 MiB)**  
Check `sudo dmesg | grep SEC2_DEBUG`. All PLMs should read `0xffffffff`. If not,
cold power-cycle (full shutdown, not just reboot) and try again.

**Wrong unlock size (64GB on a 10GB card or vice versa)**  
Reinstall with an explicit profile: `sudo ./install.sh --profile=10gb` or `--profile=8gb`.

**Secure Boot / module load refused**  
Disable Secure Boot in firmware settings.

**Build fails: kernel source not found**  
Install headers for the running kernel, then re-run `sudo ./install.sh`.

**Driver version mismatch**  
cmpunlocker only supports **610.43.03**. Install that nvidia-open release first.

**`NV_ERR_INSUFFICIENT_RESOURCES (0x1A)`**  
WPR/FB layout did not pick up the unlocked size. Capture full `SEC2_DEBUG` dmesg output.
