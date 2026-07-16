# cmpunlocker

Unlock tool for the NVIDIA CMP 170HX (GA100) mining card. Removes throttling and restrictions imposed, restoring the card to full A100 compute throughput.

Targets **nvidia-open driver 580.x** on Linux.

> **AI agents:** before making any changes to this codebase, read `.ai/CONTEXT.md` for essential project context, and rules you must follow.

---

## Background

The CMP 170HX is a physically complete GA100 die — the same silicon as the A100 datacenter GPU — with compute throughput, memory capacity, and other features artificially restricted via OTP fuses and firmware-enforced register locks. This tool restores those capabilities on hardware you own.

---

## Requirements

- Linux (x86-64)
- Python 3.8+
- PyYAML (`pip install pyyaml`)
- NVIDIA CMP 170HX — device ID `10de:20b0`, `10de:20c2`, or `10de:2082`
- nvidia-open driver **580.x** installed with GSP firmware present at `/lib/firmware/nvidia/580.*/gsp_tu10x.bin`
- Root access

---

## Install

Run once. Applies the unlock immediately and installs a systemd daemon that reapplies it automatically after every reboot or driver reload.

```bash
sudo ./install.sh
```

That is the only command needed.

---

## Verification

Check that the SM clock cap is gone:

```bash
nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader
```

Follow the daemon log:

```bash
journalctl -u cmpunlocker -f
```

---

## What gets unlocked

| Feature | Status |
|---|---|
| Full SM compute throughput | ✅ Working |
| 40GB/64GB HBM2e memory | 🔧 In development |
| ECC | 🔬 Planned |
| PCIe Gen 2 | 🔬 Planned |
| NVLink | 🔬 Planned |

---

## Persistence

The unlock does not survive reboots or driver reloads on its own. The installed daemon (`cmpunlocker.service`) handles this automatically:

- **On boot**: runs the full unlock pipeline before the display manager starts
- **Every second**: checks SS0/SS1 via BAR0 and rewrites them if reset
- **On driver reload**: detects a closed PLM and reruns the full pipeline
- **Multiple cards**: all CMP 170HX GPUs present in the system are handled

The daemon is enabled at boot via systemd and restarts automatically on failure.
