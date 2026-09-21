# Optional Linux patches for full BAR1 allocation

These patches come from [Bayley's kernel changes](https://github.com/bayley/cmpunlocker/tree/5a7bb4b7e5056306fe49e8b824787659abb19914/kernel-patches).
They are separate from the NVIDIA driver patches and are **not applied by
`install.sh`**. They are not required to unlock 64 GiB of VRAM.

- `0001` budgets child alignment padding when sizing PCI bridge memory windows.
- `0002` programs supported CMP device IDs to a 64 GiB BAR1 before Linux sizes
  the BARs. It preserves Bayley's quirk implementation, including temporary
  memory-decode enablement and register-read checks.

Bayley's hardware test used Linux 7.0.12. Here, patch context is rebased for
older kernels: `0001` replaces the unique size accumulation statement; `0002`
inserts the quirk after the PCI header rather than a version-specific end of
file. Dry-run application with zero fuzz succeeds on upstream Linux v6.8,
v6.14 and v6.17. This is **not** a build or hardware test on Ubuntu's patched
kernel sources. Ubuntu 24 alone does not identify the installed GA/HWE kernel;
check `uname -r` and use the appropriate source and configuration.

## Decide whether they are needed

First install the memory unlock, cold boot, and run:

```bash
python3 tools/check-bar1.py
nvidia-smi -q -d MEMORY
```

If every CMP has a full BAR1, proceed to the P2P trial in [docs/P2P.md](../docs/P2P.md).
If BAR1 stays at 64 MiB or disappears on some cards despite sufficient firmware
MMIO space, early sizing and bridge allocation are relevant. Enable Above 4G
Decoding and check the BIOS MMIO window first; patches cannot create address
space outside the host's supported windows.

## Apply to the host's Linux source tree

Use a separate kernel build with a distinct local version and retain the stock
kernel in the boot menu. Set `CMP_REPO` to the copied repository's absolute path.
From the extracted Linux source directory:

```bash
CMP_REPO=/absolute/path/to/locker
patch --dry-run --batch --fuzz=0 -p1 < "$CMP_REPO/kernel-patches/0001-pci-size-bridge-window-for-child-alignment.patch"
patch --dry-run --batch --fuzz=0 -p1 < "$CMP_REPO/kernel-patches/0002-pci-quirk-cmp170hx-rebar-early.patch"
# Continue only if both dry runs succeed on this exact source tree.
patch --batch --fuzz=0 -p1 < "$CMP_REPO/kernel-patches/0001-pci-size-bridge-window-for-child-alignment.patch"
patch --batch --fuzz=0 -p1 < "$CMP_REPO/kernel-patches/0002-pci-quirk-cmp170hx-rebar-early.patch"
```

Build/install that kernel and its matching headers using your Ubuntu kernel
build process. Ensure the patched NVIDIA modules are rebuilt for that kernel
before relying on the unlock. After booting it, recheck **every** card's BAR1
and follow the content-test steps in `docs/P2P.md`.

The EPYC motherboard's MMIO sizing and PCIe layout are host-specific. No ACS
addresses, IOMMU-off flags, or automatic kernel replacement are included.
Future stock kernel updates omit these changes; booting the retained stock
kernel is also the rollback for these two patches.
