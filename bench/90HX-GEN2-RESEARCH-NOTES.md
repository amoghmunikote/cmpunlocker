# CMP 90HX (GA102) PCIe Gen2 unlock (rejoin16)

Restores PCIe Gen 2 (5.0 GT/s) on the NVIDIA CMP 90HX, which ships fused to
Gen 1 (2.5 GT/s) x4. Complements the
[pearlfortune/cmpunlocker](https://github.com/pearlfortune/cmpunlocker)
compute unlock (which this builds on top of).

Verified end state: `LnkCap: Speed 5GT/s`, `LnkSta: 5GT/s (ok)`,
`nvidia-smi --query-gpu=pcie.link.gen.current` = 2, compute still
full-speed (`PASS_CMP90HX_ALL_TARGETS_FULL_SPEED`), Vulkan/CUDA unaffected.

---

## Requirements

- CMP 90HX, PCI ID `10de:220d`, subsystem `10de:1555`
- NVIDIA **open** kernel modules `610.43.03` (the pearlfortune compute unlock
  must be installed/working first; see its README)
- Kernel headers for the running kernel, `make`, `gcc`, `patch`, `binutils`
- Secure Boot disabled (patched modules are unsigned)
- No workloads on the GPU while applying (the apply reloads the driver 34
  times)

> **HOST-CRASH WARNING:** every write here is non-persistent (nothing touches
> OTP/fuses), but a botched PCIe link write can wedge the GPU until reboot -
> and on machines where the GPU shares a PCIe switch with the NIC/SATA, a
> wedged GPU can take the whole host down. See "Hazards" before running
> anything by hand.

---

## Build

The unlock is one patch (`90hx/0016-...-rejoin16-pcie-jtag-plm.patch`) applied
on top of pearlfortune's 90HX stockflow patch series, built into patched
`nvidia*.ko` modules.

```sh
# 1. Fetch and unpack the pearlfortune v0.1.28 90HX stockflow bundle
#    (see pearlfortune README section 2.1 for the download + checksum steps)
tar vxzf cmpunlocker-v0.1.28-linux-x64-90hx-stockflow.tar.gz
cd cmpunlocker-v0.1.28-linux-x64-90hx-stockflow/stockflow/610.43.03

# 2. Add the rejoin16 patch and the build variant wiring from this repo
cp /path/to/this/repo/90hx/0016-6104303-cmp90hx-stockflow-rejoin16-pcie-jtag-plm.patch patches/
cp /path/to/this/repo/90hx/build-candidate-with-rejoin16.sh ./build-candidate.sh

# 3. Get the matching NVIDIA open kernel source (pinned + sha256-checked)
wget -c https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz

# 4. Build (takes a few minutes; JOBS=1 on low-memory machines)
JOBS=$(nproc) CMP90_STOCKFLOW_VARIANT=rejoin16 \
  ./build-candidate.sh --source-tarball "${PWD}/NVIDIA-kernel-module-source-610.43.03.tar.xz"
```

Success: `PASS_CMP90HX_6104303_STOCKFLOW_REJOIN16_BUILD` and an artifact dir
`artifacts/610.43.03-$(uname -r)-rejoin16-pcie-jtag-plm/`.

## Apply (runtime, supervised)

From this repo (paths auto-detect the card's BDF; override with `CMP90_BDF`
if needed; point `CMP90_ARTIFACT` at the artifact dir built above):

```sh
sudo CMP90_ARTIFACT=/path/to/artifacts/610.43.03-$(uname -r)-rejoin16-pcie-jtag-plm \
  bench/rejoin16-apply-all.sh
```

This runs 34 driver-reload cycles (~7-8 min), firing one crafted-Booter
register write per reload to open the PCIe privilege masks (the GA102 V67
chain fires exactly once per FLR-separated module load). On the final load
the patched module itself applies the Gen2 speed-path configuration and
retrains the link in kernel context. Success: the script ends with
`phase3 link speed after retrain: 5.0 GT/s PCIe`.

## Persist across reboots

PLMs re-latch locked on every cold boot, so the apply must re-run once per
boot. Install the built modules into an isolated updates path (they take
priority over stock) and enable the boot service:

```sh
# modules (mirrors what stockflow-install.sh does for rejoin15)
sudo install -m644 artifacts/...-rejoin16-pcie-jtag-plm/*.ko \
  /usr/lib/modules/$(uname -r)/updates/cmpunlocker-90hx-stockflow/
sudo depmod; sudo update-initramfs -u   # or your distro's equivalent

# boot service: edit ExecStart path in systemd/cmp90hx-gen2.service first
sudo cp systemd/cmp90hx-gen2.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable cmp90hx-gen2.service
```

The service adds ~7-8 min to boot (the 34 reload cycles). If your miner or
GPU workload auto-starts, order it `After=cmp90hx-gen2.service`.

## Verify

```sh
cat /sys/bus/pci/devices/<BDF>/current_link_speed    # 5.0 GT/s PCIe
nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader   # 2
sudo ./cmpunlocker-rs compute90hx-v67 verify --all-cmp90hx --expect full
```

## How it works

- The CMP 90HX's Gen1 cap is enforced by PLM-protected (privilege-locked)
  registers in the XVE/XP3G PCIe blocks, not by a hard PHY fuse.
- pearlfortune's compute unlock already injects a crafted payload into the
  SEC2 Booter's signature buffer during GSP boot (the "V67 chain"), yielding
  one privileged BAR0 write per boot to open `FEAT_OVR_PLM`.
- Measured on GA102: the chain re-fires **only once per FLR-separated module
  load** (first Booter execution after FWSEC/FRTS). rejoin16 reads one
  (addr, value) pair per load from
  `/var/lib/cmpunlocker-rs/rejoin16-next-write.bin` (8 bytes, little-endian)
  and fires it; `bench/rejoin16-cycle.sh` performs one reload per register.
- 34 registers are opened: XVE masks x6, XP3G masks x17, OPTB masks x10,
  `FEAT_OVR_ECC_PLM`. (This full set is proven; the minimal subset is
  unknown - see "open questions".)
- With masks open, the module writes the Gen2 speed path (`PRIV_MISC_1`,
  `CYA_0`, XP3G OVR/VAL, `LINK_CONFIG_0` MAX_RATE=2, LTSSM override) **from
  kernel context at two controlled points** (late-boot after the stock Booter
  Load, and post-init at first device open), then sets target-link-speed on
  the GPU and upstream bridge and toggles the bridge Retrain-Link bit.

Doing the speed-path writes in kernel at those points is what makes this
stable; doing them from userspace races GSP-RM's link management and is a
coin flip on wedging the card (see Hazards).

## Hazards (learned the hard way)

- A wedged GPU (BAR0 reads return `0xffffffff`, card falls off the bus)
  recovers only via reboot. If the GPU shares a PCIe switch with other
  devices, the host may reset within minutes - with no kernel panic logged.
- NEVER write `PL_LINK_RATE` (`0x8c1c0`) before `LINK_CONFIG_0`.
- NEVER bounce the physical link (LNKCTL Link Disable) with the driver loaded.
- NEVER keep poking the card once BAR0 reads return `0xffffffff`.
- PCI remove+rescan may restore config space but does not clear a wedge.
- `OPT_GEN23` (`0x82057c`) and `VSEC_DEVICE` (`0x8860c`) do not take writes
  even via the chain (fuse-shadowed) - harmless to skip.

## Open questions / status

- **Cold boot**: warm reboots preserve the full Gen2 config (card POSTs at
  Gen2). The complete relock -> 34-cycle reapply path is implemented in the
  boot service but a true cold-power-cycle validation is pending.
- **Minimal PLM set**: the 34-write table is the proven-superset; bisecting
  the minimal subset costs one cold boot per test.
- **JTAG (Host2Jtag)**: unsolved on GA102. The GA100 PJTAG PLM addresses
  (`0xc840`/`0xc848`) are unmapped on GA102 (region returns `0xbadf1xxx`);
  the GA102 PJTAG block location is not publicly documented.

## Files

- `90hx/0016-...-rejoin16-pcie-jtag-plm.patch` - the kernel patch
- `90hx/build-candidate-with-rejoin16.sh`    - build script with rejoin16 variant
- `bench/rejoin16-cycle.sh`     - one payload write per module reload
- `bench/rejoin16-apply-all.sh` - full apply (34 cycles + verify + retrain)
- `bench/retry-gen2-train.sh`   - userspace LTSSM+retrain only (safe subset)
- `bench/bar0peek.c` / `bar0poke.c` / `plmscan.c` - BAR0 probe tools
- `bench/vkenum.c` / `vkprobe.c` / `vkrender.c` + `spirv_gen.py` - Vulkan
  capability probes (headless offscreen rendering proof)
- `systemd/cmp90hx-gen2.service` - boot-time application
- `verify-90hx-unlock.sh`       - post-boot compute-unlock verification
