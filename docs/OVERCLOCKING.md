# Use 170tune with this driver

Keep using [170tune](https://github.com/cachenetics/170tune). Our Akumaburn base
opens the HBM memory and PLL privilege masks, including every accessible unicast
FBPA PLL window. Those changes remain present with P2P off, BAR1 P2P, mailbox P2P,
and `--no-gen2`.

170tune already provides live memory-clock, timing, refresh, and SM tuning, plus
per-card correctness qualification and optional persistence. The asm64 fork's
overlapping clock/timing scripts and driver-baked `--mclk-ndiv`/`--mclk-timings`
options are not imported. A driver-baked memory clock conflicts with 170tune's
stock-clock baseline checks. Board power limits remain available through
`nvidia-smi -i <index> -pl <watts>` within each card's supported range.

## On the Ubuntu GPU host

First cold boot into the memory-unlocked driver and validate the memory and your
chosen P2P transport at stock clocks. Stop GPU workloads before tuning. Install a
CUDA toolkit with `nvcc`, CUDA/NVML development headers and libraries, and the
usual C/C++ build tools. 170tune builds its helpers from source; the CUDA helpers
are necessary for its integrity gates even if the installer permits skipping them.

For live BAR0 access, 170tune requires `iomem=relaxed`. On a GRUB Ubuntu install,
add that token to the existing `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`,
preserving your other settings, run `sudo update-grub`, and reboot. Our installer
does not add it automatically. This permits userspace access to device memory;
it does not disable IOMMU or replace PCIe routing checks.

```bash
git clone https://github.com/cachenetics/170tune.git
cd 170tune
sudo ./install.sh

# Inspect each card separately. Use the GPU indices printed by nvidia-smi.
nvidia-smi --query-gpu=index,pci.bus_id,uuid,memory.total --format=csv
sudo 170tune -i 0 preflight
sudo 170tune -i 1 preflight
sudo 170tune -i 2 preflight
```

Once preflight passes with stock clocks, save each card's own baseline:

```bash
sudo 170tune -i 0 snapshot-stock
sudo 170tune -i 1 snapshot-stock
sudo 170tune -i 2 snapshot-stock
170tune explain
170tune explain-hbm
170tune help
```

Use the upstream [tuning guide](https://github.com/cachenetics/170tune/blob/main/docs/tuning-guide.md)
to qualify a setting per card, including a hot full-memory correctness check and
your actual workload. Do not copy a recommended NDIV to all twelve cards or save
an already-tuned state as stock. After tuning, rerun the P2P content test and your
application's multi-GPU workload before enabling 170tune persistence.

If preflight reports a fenced/orphaned FBPA PLL window, inspect:

```bash
sudo dmesg | grep -E 'FBPA.*PLL|SEC2_DEBUG'
```

Akumaburn's diagnostics distinguish populated-but-unreachable windows from
inactive/fused-off FBPAs. The driver cannot make an orphaned window answer; do
not bypass 170tune's check. This source review preserves the required access but
cannot establish that every physical card exposes it.

Compatibility reviewed against [170tune 93d0e72](https://github.com/cachenetics/170tune/tree/93d0e727e70a9d1af4b2bcbddda8f8709dd6664a).
No clocks were changed and no tuning tool was installed on the development Mac.
