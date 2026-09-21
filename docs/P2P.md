# CMP 170HX memory unlock and experimental BAR1 P2P

This checkout uses [akumaburn/cmpunlocker2 at `8469dd9`](https://github.com/akumaburn/cmpunlocker2/commit/8469dd9754ba578ff984e197978f6b59bbd369e3)
as its base, including the HBM PLL/memory privilege-mask changes. The original
`master` branch remains available locally. P2P changes are on `cmpunlocker2-p2p`.

## What is needed

The base already unlocks **64 GiB on 8 GB cards (`10de:20c2`)** and 40 GiB on
10 GB cards (`10de:2082`). `--profile=8gb` cannot turn a 10 GB card into a
64 GiB card: geometry is selected by device ID.

P2P is separate. The base's BAR1 resize patch does not implement the peer
mapping path. This port adds that path, the firmware capability override,
the mailbox pre-registration fix, and the host read-capability override.
They are applied **only with `--p2p`**. Builds without that option retain the
base's P2P behavior; changing the option invalidates the build cache.

Source: [Bayley's `5a7bb4b`](https://github.com/bayley/cmpunlocker/tree/5a7bb4b7e5056306fe49e8b824787659abb19914).
The [Satspace Static BAR1 result](https://github.com/satspace-cpu/cmp170hx-linux-p2p/blob/fe0fddf165238625a13876ce63b0f37d1bd5cb2a/docs/STATIC-BAR1-P2P.md)
uses the same three transport patches: its preserved `0011`, `0013`, and
`0015` files are byte-for-byte identical to Bayley's. It adds evidence from
another host, not a different transport implementation. Its 5.30 GB/s result
used Gen2 **x16** links; only one pair in its three-GPU configuration supported
direct P2P. That throughput and connectivity are not predictions for an EPYC
system or Gen2 x4 links.

| Local patch | Source / purpose |
| --- | --- |
| `p2p-caps.patch` | Bayley's `0007` hook and `cmpUnlockForceP2PCaps`, inlined |
| `p2p-bar1.patch` | `0011`: BAR1 transport HALs and peer PTE/physical-address translation |
| `p2p-skip-mailbox.patch` | `0013`: keep mailbox peer IDs from blocking BAR1 selection |
| `p2p-read-cap.patch` | `0015`: opt-in override of NVIDIA's host read whitelist |
| `kernel-patches/` | Early 64 GiB BAR1 allocation and bridge-window alignment fix |

The port selects the five BAR1 HALs when constructing a CMP GPU's bus, rather
than changing generated defaults for all GPUs. PTE rewriting and the mailbox
exception are also CMP-scoped. The read-cap patch no longer depends on a disabled
debug patch. The unrelated Blackwell UVM modification and global suppression of
IOVAS lifetime diagnostics were not imported. Existing BAR1 resizing and the
base's reserved-memory protection are retained. This is an adapted port, not
a hardware-validated copy of either author's complete installation.

## Ubuntu 24 / EPYC / ROMED: start with three cards

Run these commands on the **Linux GPU host**, from this repository. No driver,
firmware, BIOS setting or kernel was installed on the development Mac.

1. Enable Above 4G Decoding and provide enough firmware MMIO address space.
   Install matching kernel headers, build tools, Python/PyYAML, and the NVIDIA
   **open** driver with matching userspace/firmware. Supported source versions
   are listed in `driver/VERSION`: 615.71.09, 610.57.04, 610.43.03, 610.43.02.
   Satspace's transfer evidence is for 610.57.04; newer versions are not thereby
   hardware-validated. Record the actual kernel and topology:

   ```bash
   uname -r
   lspci -Dnn -d 10de:
   lspci -tv
   nvidia-smi topo -m
   cat /proc/cmdline
   ```

2. Establish the memory unlock first:

   ```bash
   sudo ./install.sh --no-passthrough --no-iommu
   sudo shutdown -h now
   # Power the machine back on, then:
   sudo ./verify.sh
   nvidia-smi --query-gpu=index,pci.bus_id,memory.total --format=csv
   nvidia-smi -q -d MEMORY
   python3 tools/check-bar1.py
   ```

   `--no-passthrough` skips VFIO setup for this bare-metal trial.
   **`--no-iommu` leaves existing boot settings alone; it does not disable IOMMU.**
   Memory should be approximately 64 GiB per 20c2 card, less driver reservations.
   The BAR1 check requires an assigned 64 GiB PCI resource on every CMP GPU,
   independently of the reported VRAM size.

3. If BAR1 is small or missing, follow [kernel-patches/README.md](../kernel-patches/README.md).
   Driver-time resizing can be too late for the parent bridge windows. Kernel
   patches are unnecessary for the memory unlock and may be unnecessary for
   P2P if every card already gets a full BAR1 and passes real transfers.

4. Once all BAR1 checks pass, build the P2P variant:

   ```bash
   sudo ./install.sh --p2p --no-passthrough --no-iommu
   sudo shutdown -h now
   # Power the machine back on, then:
   python3 tools/check-bar1.py
   grep RegistryDwords /proc/driver/nvidia/params
   nvidia-smi topo -p2p r
   nvidia-smi topo -p2p w
   ```

   The installer writes one combined Gen2/P2P `NVreg_RegistryDwords` setting
   **before rebuilding initramfs**, including `RMForceStaticBar1=1` and
   `RMPcieP2PType=1`. Check for conflicting NVIDIA options left by earlier
   experiments in `/etc/modprobe.d`. Do not add a competing `ForceP2P=0x11`
   setting or Satspace's host-specific link-speed settings. Installation and
   removal leave the running NVIDIA driver loaded until cold boot.

5. Compile and run the content test using a CUDA toolkit with `nvcc`:

   ```bash
   nvcc -O2 -arch=sm_80 -o /tmp/cmp-p2p-test tools/p2p-test.cu
   /tmp/cmp-p2p-test 3
   sudo dmesg -T | grep -Ei 'NVRM: Xid|AER:|CMPUNLOCK_P2P|static.*bar1'
   ```

   All **6 directed pairs** must pass peer copies, direct SM reads and direct
   SM writes for a fully connected three-card setup. Distinct source/destination
   patterns and local-buffer guards detect silent local aliasing. The test
   fails for unavailable peer access; it does not count a host-staged copy as
   evidence of direct P2P. `topo`/`canAccessPeer` success alone is insufficient
   because this driver overrides capability reporting.

   To isolate a pair, use e.g. `CUDA_VISIBLE_DEVICES=0,1 /tmp/cmp-p2p-test 2`.
   Match the printed PCI addresses to the slots you intend to test. A passing
   pair does not establish connectivity to a third card.

## Host routing and scaling to twelve cards

Neither cited result validates this EPYC/ROMED configuration. Satspace used
IOMMU disabled; Bayley describes its own host configuration. If transfers fail
despite full BAR1, investigate IOMMU translation, ACS redirection and the actual
PCIe root path. Changing IOMMU/ACS affects DMA isolation and VM passthrough;
this installer deliberately does not guess such changes for the EPYC host.
`--p2p` does not alter PCIe lanes or make unsupported routes work.

Twelve 64 GiB BAR1 resources need **768 GiB of device MMIO space before bridge
alignment overhead**, in addition to other devices. That is address space, not
system RAM. Budget based on the actual switches/root ports and available BIOS
MMIO window; do not copy Bayley's switch addresses or `hpmmioprefsize` blindly.

After adding cards, run `/tmp/cmp-p2p-test 12`: a complete result has **132/132
directed pairs**. Connections are tested sequentially and disabled between
pairs. This does not establish that all eleven peers per GPU can remain mapped
at once, or that NCCL/vLLM can use that topology. Validate the application's
concurrent peer usage separately; group workloads around verified routes.

## Rollback and updates

To keep the memory unlock but remove P2P, rerun `install.sh` **without `--p2p`**
and cold boot. It rebuilds without the optional patches and removes static BAR1
options from its module configuration. `sudo ./remove.sh --yes` removes the
patched NVIDIA modules and their module options; cold boot to activate stock
modules. Separately installed custom Linux kernels remain installed.

As in the base repository, rerun installation after kernel or NVIDIA driver
updates. A stock replacement kernel does not include the BAR1 allocation
patches. Keep a working stock kernel available in the boot menu.

## Validation limits

Local validation: **58 tests passed, 1 skipped**. This includes patch application
for all four listed driver versions with P2P off/on, and Linux x86-64
cross-compilation of the changed resource-manager C files and the base's GSP
unlock file on all four versions. The Linux passthrough-module build was skipped
on macOS. Shell syntax, ShellCheck, constants and BAR1 preflight tests also passed.

These checks cannot prove correct DMA routing, memory stability, CUDA correctness
or performance on physical cards. Full kernel-module builds and compilation/run
of the CUDA content test still need the Linux GPU host.
