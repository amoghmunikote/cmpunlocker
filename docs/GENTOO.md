# cmpunlocker on Gentoo

On Gentoo you should **not** use `install.sh` to build the kernel modules:
`x11-drivers/nvidia-drivers` (>= 595) builds the *open* kernel modules from
the official `NVIDIA-kernel-module-source-<PV>.tar.xz` distfile, which is the
same tree cmpunlocker patches. So instead of building a shadow set of `.ko`
files, let Portage build the unlocked modules itself by feeding the unlock
patches through Portage's **user patches** feature
(`/etc/portage/patches/<category>/<pn>/`).

## TL;DR

```sh
# from a clone of this repo
sudo ./install.sh --gentoo
sudo emerge -1v =x11-drivers/nvidia-drivers-<PV>     # PV auto-detected by the installer
# the build log MUST show: "Applying user patches from /etc/portage/patches ..."
sudo shutdown -h now        # cold reboot
```

`--gentoo` replaces the module build step of `install.sh` with the Portage
patch installer, detects the supported `nvidia-drivers` version via Portage
(installed versions first, then the tree), and still does all the system
configuration itself (modprobe Gen2 option, gen2.service, passthrough,
IOMMU). Add `--gentoo-emerge` to let the installer run the `emerge` for you
as the final step.

For a patches-only, no-system-config install (e.g. headless fleet setup),
run the underlying helper directly: `sudo tools/gentoo-patches.sh
[--version=PV] [options]` — see [Helper options](#helper-options).

## How it works

- The Gentoo ebuild (`EAPI=8`) unpacks the driver bundle and
  `NVIDIA-kernel-module-source-<PV>.tar.xz` into `${S}` (= `${WORKDIR}`) and
  renames the module sources to `kernel-module-source/`. The kernel modules
  (`nvidia`, `nvidia-drm`, `nvidia-modeset`, `nvidia-peermem`, `nvidia-uvm`)
  are then built from `kernel-module-source/kernel-open` by `linux-mod-r1`.
- For EAPI >= 7, Portage automatically applies user patches in
  `src_prepare`, **after** the ebuild's own patches: every
  `*.patch`/`*.diff` file found under

  ```
  /etc/portage/patches/x11-drivers/nvidia-drivers-<PV>/
  ```

  (also `.../nvidia-drivers/`, with slot/version variants) is applied with
  `patch -p1 -f -g0` from `${S}`, in `LC_ALL=C` **basename sort order**.
- `tools/gentoo-patches.sh` therefore:
  1. numbers the patches from `PATCH_ORDER` in `driver/build.sh`
     (`01-…` … `14-…`) so the order survives basename sorting,
  2. rewrites the diff headers (`a/src/…` → `a/kernel-module-source/src/…`,
     same for `kernel-open/`) so `-p1` lands in the right tree,
  3. verifies the whole set against the real ebuild distfile
     (`NVIDIA-kernel-module-source-<PV>.tar.xz` from `DISTDIR`, falling back
     to the GitHub `open-gpu-kernel-modules` tarball — for 615.78.08 the two
     were checked to be identical except for a `.github/` directory),
     including a final check that applying the numbered, prefixed patches in
     the Portage layout reproduces the reference tree exactly,
  4. writes the files plus a `.cmpunlocker-manifest` (so `--uninstall`
     removes exactly what was installed).
- The current patch set carries runtime, per-PCI-device-id memory geometry,
  so **one patch set covers 8 GB, 10 GB and mixed fleets**; no per-profile
  patch is needed. (If a future patch set falls back to a build-time geometry
  rewrite, the generator detects that and emits one extra numbered
  `15-geometry-<profile>.patch` for the `--profile` you selected.)

## Requirements and notes

- `x11-drivers/nvidia-drivers` with `USE=modules` (on by default) and a
  version that is both in the Portage tree and in [`driver/VERSION`](../driver/VERSION).
  Currently only some cmpunlocker-supported versions are in the tree; check:

  ```sh
  ls /var/db/repos/gentoo/x11-drivers/nvidia-drivers/
  ```

  To use an older supported version, copy its ebuild into a local overlay
  (e.g. `mydev/nvidia-drivers`), or mask the driver so it does not drift:

  ```sh
  # /etc/portage/package.mask
  >x11-drivers/nvidia-drivers-615.78.08
  ```

- The package is `-* ~amd64`; you likely already have an
  `package.accept_keywords` entry. The helper prints the exact line.
- Secure Boot must stay disabled (or you sign the modules yourself).
- Remove any previous `install.sh`-based cmpunlocker install first
  (`sudo ./remove.sh --yes`): leftover `/lib/modules/*/updates/cmpunlocker/`
  `.ko` files can shadow the ebuild-built modules. `gentoo-patches.sh` warns
  if it finds them.
- There is no `openkernel` USE flag to worry about on these versions: the
  ebuild builds the open kernel modules unconditionally.

## System configuration (not done by Portage)

The `.ko` side is now owned by Portage; the remaining bits still come from
this repo. Re-run them after a full `nvidia-drivers` remerge only if they
were removed:

```sh
# PCIe Gen2 module option
cat > /etc/modprobe.d/cmp-pcie-gen2.conf <<'EOF'
options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"
EOF

# early-boot Gen2 retrain service (optional, skip with --no-gen2-service on other distros)
sudo ./tools/service.sh install

# VM passthrough arming (optional)
sudo ./tools/passthrough-setup.sh

# IOMMU kernel parameters — add to your bootloader config:
#   Intel: intel_iommu=on iommu=pt     AMD: amd_iommu=on iommu=pt
```

## Upgrades

- **Kernel upgrade:** just rebuild modules the usual Gentoo way —
  `emerge @module-rebuild` (or `USE=dist-kernel` with `sys-kernel/gentoo-kernel`
  does it automatically). The user patches are re-applied every time.
  The only exception is the VM-passthrough helper `cmp_no_bus_reset.ko`
  (not a Portage package): rebuild it with
  `sudo ./install.sh --gentoo` (or `sudo ./tools/passthrough-setup.sh`).
- **nvidia-drivers upgrade:** check the new version is supported
  (`cat driver/VERSION`), then re-run the installer for it and re-emerge:

  ```sh
  sudo ./install.sh --gentoo      # detects the new version and installs its patch set
  sudo emerge -1v =x11-drivers/nvidia-drivers-<new-PV>
  ```

  If the tree version has no matching entry, emerge will silently build
  **stock** modules (no patch dir matches) — check the build log or
  `nvidia-smi` after rebooting.

## Staying on / going back to 615.71.09 (companion overlay repo)

The SEC2 post-BL unlock (`nv_cmp_postbl=1`, the default) is rejected by the
**615.78.08** Booter blob with `Booter failed ... error code: 0x1c` — see
*Troubleshooting* below. The unlock is known to boot on **615.71.09**
(the newest driver version the upstream author actually tested this patch
set on), but the Gentoo tree dropped 615.71.09 (commit `2f14e3192e41`).
The ebuild is kept installable in the companion **`cmpunlocker-overlay`**
repo (a sibling of this one), which holds a single category:

```
cmpunlocker-overlay/
├── profiles/repo_name                          # "cmpunlocker"
├── README.md
└── x11-drivers/nvidia-drivers/
    ├── nvidia-drivers-615.71.09.ebuild         # tree ebuild (2f14e3192e41^), MODULES_KERNEL_MAX raised 7.2 -> 7.3
    ├── Manifest                                # DIST entries from the tree + recomputed EBUILD hash
    ├── metadata.xml                            # from the tree
    └── files/                                  # aux files the ebuild installs
```

The ebuild is the unmodified tree copy (only `MODULES_KERNEL_MAX` raised to
7.3, matching the in-tree 615.78.08 bump). All cmpunlocker patches apply
cleanly and the tree builds against 7.3.x kernel sources (verified against
the GitHub `615.71.09` tag, which is content-identical to the
`NVIDIA-kernel-module-source-615.71.09.tar.xz` distfile).

Install on the target host:

```sh
# 1. register the overlay (clone the cmpunlocker-overlay repo, or copy it in)
git clone <cmpunlocker-overlay> /var/db/repos/cmpunlocker
mkdir -p /etc/portage/repos.conf
cat > /etc/portage/repos.conf/cmpunlocker.conf <<'EOF'
[cmpunlocker]
location = /var/db/repos/cmpunlocker
auto-sync = no
EOF
echo "=x11-drivers/nvidia-drivers-615.71.09 amd64" >> /etc/portage/package.accept_keywords

# 2. fetch the distfiles first, so the installer can verify the patch set
#    against the exact distfile (otherwise it falls back to the GitHub tag)
emerge -f "=x11-drivers/nvidia-drivers-615.71.09"

# 3. stage the user patches, then build
sudo ./install.sh --gentoo --version=615.71.09 --profile=8gb --no-passthrough --gentoo-emerge
sudo emerge -1v =x11-drivers/nvidia-drivers-615.71.09
```

Notes:

- 615.71.09 installs into the same SLOT (`0/615`) as 615.78.08, so the
  `emerge -1v` replaces the current patched driver. The old patch directory
  under `/etc/portage/patches/x11-drivers/` can stay; it simply stops being
  used (and `nvidia-drivers` keeps working unpatched there if you revert).
- If you used the stock-boot workaround, **remove**
  `/etc/modprobe.d/cmp-postbl-off.conf` before booting the new driver —
  testing 615.71.09 means letting the unlock run (default `nv_cmp_postbl=1`).
- Verify after reboot:

  ```sh
  dmesg | grep -E 'SEC2_DEBUG|Booter|final size'
  nvidia-smi -L && nvidia-smi --query-gpu=memory.total --format=csv
  ```

  A healthy cold boot on 615.71.09 looks like this (verified on a
  dual-CMP 8 GB box, kernel 7.3.4):

  ```text
  NVRM: GPU0 ...: Booter failed with non-zero error code: 0x31        (x ~55, ~7 s)
  NVRM: GPU0 _kgspBootGspRm: SEC2_DEBUG: POST-WRITE SS0=0x88888888 SS1=0x00000008 CFG1=0x02779000 LMR=0x0000020b (devId=0x20c2)
  NVRM: GPU0 ...: Booter failed with non-zero error code: 0x31        (more)
  NVRM: GPU0 kgspBootstrap_TU102: SEC2_DEBUG: normal BooterLoad status=0x0
  ```

  i.e. the built-in SEC2 payload is **rejected with `0x31` — which is
  non-fatal on 615.x** (unlike `0x1c` on 615.78.08, see Troubleshooting):
  the Booter survives, the kernel-side POST-WRITE applies the geometry
  directly (readback shows the `0x88888888` magic + CFG1/LMR), and the
  stock Booter Load that follows returns `0x0` with the card now
  physically at 64 GiB. All twelve `PLM[n] ... status=0xffff` lines are
  expected here too — the CMP SEC2 refuses those windows regardless;
  the unlock does not depend on them. The retry spam costs ~7 s per GPU
  at boot. What must NOT appear is `0x1c`: that poisons the stock Load;
  if you see it, restore `/etc/modprobe.d/cmp-postbl-off.conf`, reboot
  (or use the SBR recovery recipe below) and go back to 615.78.08.

## Rebooting headless / IPMI servers

A normal reboot is usually enough; the installer recommends a cold reboot as
a fallback because a warm reboot can occasionally leave the card in a state
where `nvidia-smi` still reports stock memory. Over IPMI the full power
cycle is easy:

```sh
# 1. on the server: clean shutdown
shutdown -h now

# 2. from a BMC client, once the machine is off:
ipmitool -I lanplus -H <BMC_IP> -U <user> chassis power on

# one-shot alternative (hard power cycle, skips the OS shutdown — use only
# when the box is not serving anything):
ipmitool -I lanplus -H <BMC_IP> -U <user> chassis power cycle
```

`chassis power reset` is a warm reset — prefer `off`/`on` (or `cycle`) if
memory reports stock size after a warm reboot. `ipmitool ... sol activate`
lets you watch the boot and the `gen2.service` output without a console.

## Verification

- Build log contains `Applying user patches from /etc/portage/patches ...`.
- After a cold reboot: `nvidia-smi` should report ~65536 MiB (8 GB cards) or
  ~40960 MiB (10 GB cards) and the unlocked GPU name;
  `sudo dmesg | grep SEC2_DEBUG` shows the unlock trace.
- `./verify.sh` on a Gentoo install reports the installed user-patch sets
  from `/etc/portage/patches/x11-drivers/` (the `updates/cmpunlocker`
  metadata files only exist for the legacy module-build flow).

## Troubleshooting

### BAR1 resize on multi-CMP servers: history, root cause, current design

**Concurrency.** 615.x probes each GPU in its own `nv-probe-<pci>` kthread,
so with several CMP cards the BAR1 resizes used to run concurrently. On
kernels with the 6.16+ reBAR rework (`pci_resize_resource()` now releases
and reassigns bridge windows itself via
`pci_do_resource_release_and_resize()`), two threads doing this on GPUs
that share a PCIe-switch fabric corrupt the kernel resource tree (BAR1
ending up at 0 MB / 16 GB, occasional `release_resource()` Oops). A mutex
fixes the corruption but not the layout.

**Sizing (root cause, why the kernel's allocator cannot place two cards).**
The kernel sizes every bridge window as the *plain sum* of its children's
sizes (`pbus_size_mem()`: `size += max(r_size, align)`), but places each
child aligned to its own alignment. For one CMP the leaf window must hold
BAR1 (64 GiB, 64 GiB-aligned) + BAR3 (32 MiB) → size 64 GiB + 32 MiB,
alignment 64 GiB. Two such children of the upstream window need a span of
~192 GiB (the second window must start at a 64 GiB-aligned address *past*
the first, which overshoots its 64 GiB-aligned start by the extra 32 MiB),
yet the kernel only ever sizes the parent to the 128 GiB sum → the second
card fails with `bridge window [mem size 0x1002000000 64bit pref]: can't
assign; no space` at every step-down size and ends at 64 MB. There is no
driver-side knob that makes the kernel add the alignment slack.

**Current design (`10-bar1-resize-unlock.patch`).** For CMPs the stock
resize call is not used at all. While every CMP probe is parked at a
bounded barrier, one pass re-lays out the whole chain by hand:

1. detach every CMP's BAR1/BAR3 and every prefetch bridge window on the
   paths to the host bridge (memory decoding off on the chain);
2. compute a placement: one bridge window per card, sized to a multiple
   of the BAR1 alignment (128 GiB for a 64 GiB BAR + 32 MiB BAR3),
   placed inside the largest host-bridge aperture (ACPI describes these
   as plain non-prefetchable memory on most x86 platforms, and the
   kernel allocator itself fits 64-bit prefetch bridge windows into
   them, so any MEM window qualifies, a prefetchable one preferred) —
   such windows tile their ancestors gaplessly, alignment included;
3. claim the placement top-down in the kernel resource tree via
   `pci_claim_resource()` and program the bridge window registers,
   the reBAR control fields and the BAR registers directly;
4. on any failure everything is rolled back to the firmware placement
   (cards boot at stock 8 GiB) and the boot continues.

Servers are still the worst case: CMPs behind a PLX PEX87xx chain share
bridge windows with the rest of the fabric. After a resize always check
that *all* GPUs are present (`nvidia-smi -L`, `lspci -nn`) and that
unrelated bridge windows were not reassigned.

Diagnostics:

- `dmesg | grep -E "CMP BAR1"` — the pass announces itself
  (`coordinated layout for 2 CMP device(s)`), prints the chosen host
  window (`host window [0x...-0x...], 131072 MiB window x 2`) and per
  card `<pci> BAR1 = 65536 MiB @ 0x...`; the probe site then prints
  `final size = 65536 MB` for every card.
- `lspci -vvv -s <GPU>` — BAR 1 `64-bit, prefetchable` `[size=64G]`, and
  BAR3 at BAR1+64 GiB inside the same window; check the whole chain up
  to the root port (`lspci -t`, then `lspci -vvv` per bridge).

Requirements: the host bridge needs an aperture of at least ~128 GiB per
card (256 GiB for two 64 GB cards) — enable `Above 4G Decoding` / a large
`MMIO High Size` in the BIOS, and every bridge window on the path to the
cards must be 64-bit prefetchable (the pass prints `bridge ... has only a
32-bit prefetch window` if not). If placement fails the kernel log shows
`layout failed (...); restoring firmware placement` and, for a missing
aperture, dumps the actual root-bus windows
(`no host window >= ... MiB ...; candidates:` + one line per window).

Verified on a dual-CMP 170HX (8 GB) AMD server, kernel 7.3: host window
`0x28000000000-0x2ffffffffff`, both cards `BAR1 = 65536 MiB` @
`0x28000000000` / `0x2a000000000`, `final size = 65536 MB` each.
A small BAR1 still boots; it only limits CPU-side framebuffer mapping and
VM passthrough, not the VRAM unlock itself — `nv_cmp_force_rebar=0`
(below) turns the unlock off entirely for diagnostics.

### Escape hatch: `nv_cmp_force_rebar`

The patch set normally forces `NVreg_EnableResizableBar=1` on CMP GPUs at
probe. To boot with the stock resize policy (no BAR1 resize unlock) for
diagnostics, without rebuilding:

```sh
echo "options nvidia nv_cmp_force_rebar=0" | sudo tee /etc/modprobe.d/cmp-unlock-test.conf
sudo modprobe -r nvidia && sudo modprobe nvidia   # or just reboot
```

### Escape hatch: `nv_cmp_postbl=0` (and the marker file)

The GSP-side unlock (`01-sec2-postbl-plm-ss-cfg.patch`) replaces the GSP
boot signature with a custom payload and opens the PLM/CFG1/LMR geometry
*before* the Booter load; `07-pcie-gen2` (its `kernel_gsp.c` part) and
`12-ecc-enable` add writes inside the same guarded block. If that path
fails on a given driver version or board, the whole GSP boot fails
(`Booter failed ... error code: 0x1c`, `RmInitAdapter failed`), even
though none of it is needed for the cards to work — they just stay at
their locked capacity.

To boot the CMP cards through the completely stock GSP path without
rebuilding, use the module parameter (checked once per module load —
reboot or reload the module after toggling):

```sh
echo "options nvidia nv_cmp_postbl=0" | sudo tee /etc/modprobe.d/cmp-postbl-off.conf
# back to unlocked boot path:
sudo rm /etc/modprobe.d/cmp-postbl-off.conf
```

The marker file `/etc/nvidia/cmp-postbl.disabled` does the same but is
**best-effort only**: the gate runs in the `nv-probe` kthread, where the
RM OS layer may be unable to resolve paths (`os_open_readonly_file()`
collapses every failure, including `current->fs == NULL`, into
`NV_ERR_OPERATING_SYSTEM` 0x59) — this bit us in practice: a marker that
plainly existed was reported as absent. Do not rely on the marker; use
the parameter.

`dmesg | grep "postbl"` confirms: `SEC2_DEBUG: postbl DISABLED (param=0
marker ... status=0x... ctx=0x...)` or `postbl enabled`. The `status` /
`ctx` fields show the raw open result and whether the check ran in a
kernel thread — useful when debugging why the marker was not seen.

### `Booter failed ... error code: 0x1c` on newer driver versions

The built-in GSP payload of `01-sec2-postbl-plm-ss-cfg.patch` is a fixed
capture: its command bytes have been unchanged since the upstream
"Memory working!" commit, which was made when `driver/VERSION` still
listed only 610.43.02/610.43.03; the 615.x support commits were
context-only ports plus a one-line `VERSION` bump. The Booter is a
binary inside the driver's `gsp_ga100.bin`, so a payload that the 610.x
Booter executes can be rejected outright by a 615.x Booter — the
signature is then never executed, every PLM register stays locked, and
the stock Booter Load that follows is poisoned by the failed attempts
(`0x1c` in mailbox0, `RmInitAdapter failed (0x62:0xffff:2130)`).

If `Booter failed ... error code: 0x1c` reproduces on every attempt with
the built-in payload (`using built-in payload` in dmesg), that is the
likely cause, not your hardware. Verified on a dual-CMP box that the
rejection is independent of the card's prior state: booting the cards
stock with `nv_cmp_postbl=0` (healthy 8 GB, `nvidia-smi` works), then
removing the option and reloading the module — the payload path still
fails with `0x1c` on the first PLM entry, and the failed attempts
poison the stock Booter Load that follows (both GPUs disappear from
`nvidia-smi` until the next `nv_cmp_postbl=0` reload). The upstream
"unlock after FLR" recipe does not reproduce on 615.78.08.

On **615.71.09** the same built-in payload is rejected too, but with a
*different* code — `0x31`, and crucially the Booter is **not poisoned**:
the kernel-side POST-WRITE applies CFG1/LMR directly and the stock
Booter Load that follows returns `0x0` with the cards physically
reconfigured (64 GiB, verified cold-boot on a dual-CMP box, kernel
7.3.4; see *Staying on / going back to 615.71.09* above). The `0x31`
vs `0x1c` difference is the cleanest evidence that the regression is in
the 615.78.08 Booter blob itself, not in the patch set. Options: run
615.71.09 via the bundled overlay (recommended, fully working), boot
the CMPs stock with `nv_cmp_postbl=0` (locked capacity — the
`/etc/nvidia/cmp-postbl.disabled` marker does not work on 615.x, see
below), or obtain a driver-version-matched `dmem.bin` payload from the
project (see `SEC2_POSTBL_TIMING_DMEM_PATH`). Caveat for 615.x: the `dmem.bin` read
happens in the same kthread context as the marker above, and the old
logs collapsed every failure into 0x59 (`NV_ERR_OPERATING_SYSTEM`,
generic — *not* "file not found"), so a `not found (0x59)` line there
does not prove the file was missing; the current patch logs the raw
status for the marker, and the parameter escape hatch sidesteps the
whole issue.

### Recovering the cards after a poisoned Booter attempt

Failed payload attempts leave the GSP/WPR2 state dirty: `rmmod`/`modprobe`
does NOT clear it (stock re-init then fails with `normal BooterLoad
status=0xffff`, `nvidia-smi` empty), and on this platform neither the
GPU (no FLR capability) nor the PLX DSP (`reset` sysfs → `ENOTTY`) can
be reset through the kernel's reset paths. What works, no reboot:

```sh
modprobe -r nvidia
# manual PCIe hot reset (SBR) on the DSP above each card:
setpci -s 84:08.0 BRIDGE_CONTROL.w=0040; sleep 1; setpci -s 84:08.0 BRIDGE_CONTROL.w=0000
setpci -s 84:10.0 BRIDGE_CONTROL.w=0040; sleep 1; setpci -s 84:10.0 BRIDGE_CONTROL.w=0000
# SBR clears the endpoints' BAR registers — make the kernel re-assign them:
echo 1 > /sys/bus/pci/devices/0000:85:00.0/remove
echo 1 > /sys/bus/pci/devices/0000:86:00.0/remove
sleep 1; echo 1 > /sys/bus/pci/devices/0000:84:08.0/rescan
sleep 1; echo 1 > /sys/bus/pci/devices/0000:84:10.0/rescan
sleep 2; modprobe nvidia; nvidia-smi -L
```

The bridge windows survive SBR (it only resets the secondary side), so
the coordinated resize pass re-places the BARs at boot addresses on the
next module load. If the link itself stays dead (`lspci` cannot read
the GPU) or the cards still fail, use a chassis power cycle (warm
reboot may not reset GSP state).

### Bisecting the patch set without Portage rebuilds

Portage user patches are plain files — test subsets by moving them out
and re-emerging:

```sh
sudo mv /etc/portage/patches/x11-drivers/nvidia-drivers-<PV>/07-pcie-gen2.patch /root/
sudo emerge -1v =x11-drivers/nvidia-drivers-<PV>
```

Useful first experiments when GSP boot fails (`Booter failed ... error
code: 0x1c`, `RmInitAdapter failed (0x62:0xffff:2130)`):

1. `options nvidia nv_cmp_postbl=0` + `nv_cmp_force_rebar=0` + reboot —
   the two escape hatches together take the driver back to a near-stock
   runtime with no rebuild. If GSP boots now, the culprit is the
   pre-Booter block or the resize, not the remaining patches.
2. `nv_cmp_force_rebar=0` alone — isolates the BAR1-resize part.
3. `nv_cmp_postbl=0` alone — isolates the GSP payload/PLM/geometry part;
   if `Booter 0x1c` is gone, the payload (or its interaction with this
   driver version/board) is the culprit. A useful follow-up: with the
   cards up stock (8 GB), `rm` the option and `modprobe -r nvidia &&
   modprobe nvidia` — that retries the payload on top of a stock-
   initialized card (WPR2 already up), which is the scenario the
   upstream project reports working (`BooterLoad status=0x0`).
4. Drop `07-pcie-gen2.patch` + `08-pcie-gen2-probe-retrain.patch` —
   isolates the PCIe Gen2/link parts.
5. Remove the whole cmpunlocker patch dir and rebuild — establishes
   whether *stock* nvidia-drivers boots GSP at all on this kernel/hardware
   (a failure here is not a cmpunlocker bug).

Always collect `dmesg` (full), `lspci -nn` and `nvidia-smi -q` when
reporting failures.

## Uninstall

```sh
sudo ./remove.sh --yes
# also removes the cmpunlocker Portage user patches (manifest-based), then:
sudo emerge -1v =x11-drivers/nvidia-drivers-<PV>
# cold reboot → stock driver
```

Patches only, without touching the system configuration:
`sudo tools/gentoo-patches.sh --uninstall --version=<PV>`.

## Helper options

```
--version=PV           target nvidia-drivers version (default: driver/VERSION first entry)
--profile=8gb|10gb|mixed
                       only used if a future patch set needs build-time geometry
--distdir=DIR          extra place to look for NVIDIA-kernel-module-source-<PV>.tar.xz
--source=auto|distdir|github
                       which pristine tree to verify against
--no-verify            skip verification (not recommended)
--dry-run              show what would be installed
--dest=DIR             override /etc/portage/patches target (testing)
--uninstall            remove exactly what was installed (manifest based)
```
