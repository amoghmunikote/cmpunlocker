# GPU-to-GPU BAR1 P2P

This ports the P2P implementation from the supplied `cmpunlocker-p2p` into
the `cmpunlocker-0.4` patch-based build. The existing memory profiles, per-device
geometry, PCIe Gen2 and passthrough implementation remain in `0.4`.

## Enable or disable

```bash
sudo ./install.sh --p2p
# Existing flags can be combined with --p2p:
sudo ./install.sh --p2p --profile=10gb --no-passthrough
```

The installer passes `CMPUNLOCKER_ENABLE_P2P=1` to `driver/build.sh`. Direct
builds use the same interface:

```bash
sudo env CMPUNLOCKER_ENABLE_P2P=1 ./driver/build.sh
```

Unset, empty or `0` disables P2P; `1` enables it. Other values are rejected.
The installer uses its command-line flag as the authority: without `--p2p`,
P2P is disabled even if the calling shell exports the environment variable.

For a P2P build, `/etc/modprobe.d/cmp-pcie-gen2.conf` contains one combined
`NVreg_RegistryDwords` value:

```text
RmForceEnableGen2=1;RMPcieLinkSpeed=0x1;RMForceStaticBar1=1;RMPcieP2PType=1
```

This file is written before the build script regenerates initramfs. The installer does not overwrite it afterwards. Do not add a second competing
`NVreg_RegistryDwords` option in another modprobe file. The source branch also
reports hangs with an explicit `ForceP2P=0x11` registry option; the installer
does not add that option.

P2P builds, and the first build disabling an installed P2P configuration,
skip the live NVIDIA module reload. Shut down completely and power on again.
If initramfs generation reports a failure, correct it and regenerate initramfs
before rebooting; a stale image may still contain the previous modules/options.

To disable P2P, reinstall without `--p2p` and cold boot. The source cache is
invalidated and all four optional patches are removed by extracting a fresh
driver tree. The combined config is rewritten with only the original Gen2
settings. `remove.sh --yes` removes that config and the installed metadata with
the modules. Keep the same install flags after a kernel upgrade; this merge
retains `0.4`'s manual rebuild workflow.

## Host requirements

- Every participating CMP GPU needs BAR1 large enough to cover its unlocked
  framebuffer. The source branch's setup uses 64 GiB BAR1 on every GPU; that
  also covers the 40 GiB framebuffer of device `2082`.
- Firmware must provide enough address space for all GPU BARs and bridge
  windows. BAR1 expansion is done by the driver at probe time and depends on
  the BIOS allocating sufficient MMIO (Above-4G Decoding, large enough MMIO-H
  window). If the firmware does not provide that space, no driver-side change
  can create it; the BAR stays at its stock size and P2P will not work.
- The actual PCIe topology, ACS routing and IOMMU configuration must carry
  peer reads and writes. `0.4` retains its default IOMMU passthrough setup;
  `--no-iommu` leaves that configuration to the operator.
- A stock guest driver does not inherit these P2P source patches merely
  because an unlocked card was passed through. Guest P2P needs its own patched
  driver and working PCIe mappings in the guest/host configuration.

The source project's throughput numbers and kernel version are records of
its host, not verification of this merged tree on another machine.

## Verify real transfers

After a cold boot, check every CMP GPU, then inspect capability reports:

```bash
sudo ./verify.sh
lspci -tv
for bdf in $(lspci -Dn | awk '/10de:20c2|10de:2082/{print $1}'); do
    sudo lspci -vv -s "$bdf" | sed -n '/Region 1:/p'
done
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
```

The override makes capability reports say P2P is available. That alone cannot
show that data moves. Build the included CUDA test with a CUDA toolkit:

```bash
nvcc -O2 -arch=sm_80 -o /tmp/cmpunlocker-test-p2p tools/test-p2p.cu
timeout 120s /tmp/cmpunlocker-test-p2p
# Or select CUDA device indices (including two devices across switches):
timeout 120s /tmp/cmpunlocker-test-p2p 0 1
```

The test runs a GPU kernel for both peer reads and peer writes for every
ordered pair. It initializes the endpoints with different patterns, checks
the copied bytes and verifies the source is unchanged. This detects local
memory aliasing that a simple capability check can miss. CUDA errors,
unavailable peer access or data mismatches return a nonzero exit status;
`timeout` bounds a userspace wait, but cannot recover a wedged GPU/host.

The included test is a correctness test, not a bandwidth benchmark. The
source branch's `benchmark/nvidia_bench.cu` is a single-GPU benchmark, so it is
not used to claim P2P success.

## Implementation map

All four patches below are in `driver/patches/p2p/` and applied only with
`--p2p`, after the original `0.4` patch sequence:

| Patch | Implementation |
| --- | --- |
| `0007-p2p-caps.patch` | Inline port of `cmpUnlockForceP2PCaps`: override GSP read/write caps for PCI device IDs `20c2` and `2082`. No dependency on the other branch's unlock C file. |
| `0011-p2p-bar1.patch` | Original BAR1 HAL selection, create/remove mapping branches, CMP BIF defaults, BAR1 bus-address propagation, peer PTE/physical address rewrites, UVM coherency handling, REBAR default and IOVAS teardown changes. |
| `0013-skip-mailbox-peer-preinit.patch` | Skip mailbox peer pre-registration when BAR1 P2P is selected, leaving peer masks clear. |
| `0015-bar1p2p-readcap-override.patch` | CMP host-system read-cap override, rebased onto source without debug instrumentation. No dependency on the disabled `0014` patch. |

`0.4` already contains the functional equivalent of the source branch's
`0009-bar1-resize-unlock.patch`; it is retained, not applied twice.

The P2P feature state and selected patch bytes participate in the build cache
stamp. The installed state is recorded as `p2p_enabled` next to
`driver_version` and `card_profile`. `common/constants.yaml` records the
optional patch order and `tools/read-constants.py` checks its consistency.

As in the source branch, some changes inside `0011` affect shared HAL defaults,
the UVM coherence path and IOVAS diagnostics, not just CMP device-ID checks.
They are absent from builds without `--p2p`.

## Validation limits

The source branch lists NVIDIA `610.43.03` and `610.43.02`. The base project's
version list is retained (`615.71.09`, `610.57.04`, `610.43.03`, `610.43.02`).
P2P patches are applied with full context matching (`--fuzz=0`); a changed
driver API/context stops preparation instead of silently skipping a patch.
Retaining the version list does not establish P2P build compatibility on each
version. Full NVIDIA module builds and real CMP transfer
tests must still be run in the target environment.

Offline regression checks are available with:

```bash
python3 -m unittest discover -s tests -v
```

