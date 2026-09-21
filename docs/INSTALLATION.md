# Installation

Here are the steps to install cmpunlocker on your system.

---

## Requirements

- Linux (x86-64)
- Root access
- NVIDIA CMP 170HX
- **A supported nvidia-open version from `driver/VERSION` already installed** (matching libs + firmware)
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads matching stock `open-gpu-kernel-modules` sources)
- Python 3 and PyYAML (`python3-yaml` on Ubuntu)

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

To force a certain memory profile, use the `--profile` option:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

Then power off and power on (cold boot).

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./remove.sh --yes
```

Then power off and power on (cold boot).

## P2P, maintenance and tuning

For the Ubuntu 24 / EPYC three-card trial, follow [the P2P guide](P2P.md).
`--p2p` selects static BAR1; `--p2p=mailbox` selects the small-BAR1 alternative.
Both are experimental and need actual peer-transfer validation.

Automatic kernel/header rebuilds and apt holds are enabled by default; see
[maintenance and recovery](PERSISTENCE.md) for status, logs, opt-outs and rollback.
`--no-gen2` disables both driver retrain patches and the boot retrain service.

Use [170tune](OVERCLOCKING.md) for per-card runtime overclocking. This driver
preserves Akumaburn's required HBM privilege masks and does not bake in clocks.
