# Experimental C0330C geometry checks

This adds guarded initialization for the observed CMP 170HX (`10de:20c2`)
with FBPA/FBIO disable mask `0x00c0330c`, FBP disable mask `0x852`, and
`PMC_BOOT_0=0x170000a1`. It uses the existing 8 GB profile; no new profile or
installer option is required.

Upstream commit `76f0954` already removed the allowlist that kept this topology
at 8 GiB. This patch adds checks around that variant's geometry transition;
it does not claim the current upstream still rejects the card. Other masks
retain current upstream behavior, including the 32 GiB ES special case.

## Behavior

Before changing geometry, require the measured stock CFG1 `0x02449000`, CSTATUS
`0x200`, HBM_CFG0 `0xa7`, and LMR `0x208`. Check all 16 enabled FBPAs and the
broadcast registers. After writing CFG1 `0x02779000`, require every enabled FBPA
to report CSTATUS `0x1000` before writing LMR `0x20b`. Recheck after GSP handoff
and validate the last framebuffer region before exposing 64 GiB. Readiness is
local to each GPU initialization attempt; successful geometry suppresses GSP
boot retries. No disabled FBPA apertures are read.

Any C0330C mismatch aborts initialization. Accepted writes are not rolled back;
a full power cycle is required after a failure. Warm module reload, resume,
GPU reset and passthrough reuse are outside this experimental path's scope.
Do not interpret a register readback or reported capacity as a memory test.
There are no new rank, floorsweep, power, clock or fan writes.

## Hardware evidence — earlier candidate, 2026-09-07

The tested candidate was based on cmpunlocker
`a3ea84b251db490d73a12b3fffbc9e6658e6b0cd`, NVIDIA `610.43.02`, and the
C0330C R1 guard patch (R2 packaging corrected GNU patch context).
It built and ran on Ubuntu x86_64, kernel `7.0.0-31-generic`, with an RTX A2000
as the separate display GPU. The CMP occupied BDF `0000:01:00.0`, negotiated
Gen2 x4, and retained a 250 W power ceiling. Exact Ubuntu release and physical
slot designation were not captured in the retained test summary.

- All four geometry checkpoints passed; the driver reported 65536 MiB.
- 62.625 GiB (67,243,081,728 bytes) remained simultaneously allocated across
  63 OpenCL buffers. Two globally address-derived complementary patterns were
  written across every buffer before each full CPU readback. Both comparisons
  passed with zero mismatches; the stage completed in 93.838 seconds.
- An additional 256 MiB scratch buffer provided cache pressure. Driver/context
  headroom and scratch are excluded from the verified-data total.
- A subsequent sustained test retained that data allocation, repeatedly checked
  it on the GPU, and completed 50 full CPU readbacks with zero mismatches before
  an intentional stop after 4 h 39 m 46.668 s. It was stopped because the card
  was being returned, not because a hardware error was observed.
- Sampled maxima during the interrupted run were 62 C GPU / 68 C memory.
  No new NVIDIA Xid or PCIe errors were observed; 114 AER counters matched their
  baseline. This was not a full-power thermal qualification.

The original supervisor results are [capacity-result.json](capacity-result.json)
and [interrupted-soak-result.json](interrupted-soak-result.json). The stopped
run has no final soak PASS. Detailed readback and telemetry logs are retained
separately; these small result files are summaries, not independently executable
proof. No claim is made about every physical byte, reserved memory, physical
address placement, repeated cold boots, or an eight-hour stability pass.

Tested patched `kernel_gsp.c` SHA-256:
`4e536e97b08321bde0b31221eaf25ec4df09ecb220d7cbcb3483a7d43d78ac39`.
Tested `nvidia.ko` SHA-256:
`3975f5fd6226cc9c7c9e58ce1b31744b83d40f3ff398bf448828749294d19b63`.

## Current integration validation

The current integration rebases the same C0330C helper/readback logic onto
`76f0954`, preserving upstream's relaxed handling of other masks and its newer
patch stack. The new integration passed a Linux module build, installation, reboot checks,
and fresh smoke/near-full memory tests on 2026-09-08. The near-full test checked
62.625 GiB through two complete readbacks with zero mismatches and zero monitor
errors. See [fresh hardware evidence](HARDWARE_VALIDATION.md), attached receipts,
and [build evidence](BUILD_VALIDATION.md). Keep this experimental: no fresh
extended soak or repeated cold-boot qualification has completed. Historical
soak results do not qualify this integration or newer NVIDIA versions.

Local checks on 2026-09-08: the full patch stack applied with GNU patch 2.8
and zero fuzz on NVIDIA 610.43.02, 610.43.03 and 610.57.04. Each passed 157
synthetic scenarios / 14,662 assertions under ASan/UBSan. Unmodified upstream
failed the readiness assertion as expected. Shell syntax and the constants
manifest validator also passed. These are source checks, not new live results.

To apply the entire patch stack to a temporary copy of a pristine extracted
NVIDIA source tree and replay the actual patched C blocks with synthetic MMIO:

```sh
python3 tests/c0330c/check.py /path/to/open-gpu-kernel-modules-610.43.02
# Optional explicit GNU patch executable:
python3 tests/c0330c/check.py /path/to/open-gpu-kernel-modules-610.43.02 --patch gpatch
```

Requires Python 3, patch, and a C compiler with ASan/UBSan. The command never
builds or installs modules and never accesses hardware. It covers successful
geometry, preflight mismatches, dropped writes, 32 GiB readback, post-GSP drift,
invalid region metadata, missing readiness, warm repeats, retry suppression,
and other-card isolation. It extracts selected actual C blocks; it is not a
full compilation of the surrounding driver functions or a GSP/HBM simulation.
The name-string hunk includes balanced context for GNU patch with zero fuzz;
its resulting C code is unchanged.
