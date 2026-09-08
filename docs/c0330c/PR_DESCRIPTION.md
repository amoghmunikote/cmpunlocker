## Summary

Add experimental geometry validation for the observed C0330C CMP 170HX variant. Upstream `76f0954` already removes its allowlist rejection; this change checks the transition before advertising 64 GiB and preserves current behavior for other masks.

## Changes

- Add exact topology and stock-state checks, per-enabled-FBPA geometry readback before expanding LMR, and post-GSP geometry/region validation.
- Keep readiness local to each GPU initialization and suppress retries after successful experimental geometry. Failed checks abort initialization; a full power cycle is required, with no runtime rollback.
- Register the patch in the build order and constants manifest; use the existing 8 GB profile.
- Balance name-string patch context for GNU patch zero-fuzz application without changing the generated C.
- Include synthetic source tests and a hardware-results report in `docs/c0330c/`.

## Testing

**Experimental: this exact integration built, was installed, rebooted, and passed fresh memory readback tests on the original C0330C card.** See `docs/c0330c/HARDWARE_VALIDATION.md` and its attached result receipts. The original build receipt and input manifest are included; PR preparation verified all 26 code, configuration and test file hashes against the tested snapshot.

- Current integration: all five NVIDIA 610.43.02 modules built on Ubuntu 26.04.1 LTS, kernel 7.0.0-31-generic. Installed hashes matched the receipt; after reboot the loaded build timestamp matched the fresh build and all four geometry checkpoints passed. Build warnings remain documented in `docs/c0330c/BUILD_VALIDATION.md`.
- Current integration: 512 MiB smoke and 62.625 GiB near-full allocation each passed two complete write/readback passes with zero mismatches and zero monitor errors (7.357 s and 92.605 s respectively). This validates the tested usable allocation, not every physical byte or long-term stability. No fresh extended soak or repeated cold-boot qualification has completed.
- Current integration: complete stack applies with GNU patch 2.8 and zero fuzz on NVIDIA 610.43.02, 610.43.03 and 610.57.04. All three pass 157 synthetic scenarios / 14,662 assertions with ASan/UBSan. Unmodified upstream fails the new readiness check as expected. Shell syntax and constants validation pass.
- Earlier candidate (`a3ea84b` + C0330C R1 guards, R2 packaging): Linux build and four live geometry checkpoints passed with NVIDIA 610.43.02; driver reported 65536 MiB.
- Earlier candidate: 62.625 GiB simultaneously allocated and checked through two full CPU readbacks, zero mismatches. An additional sustained run completed 50 full readbacks with zero mismatches before an intentional stop after approximately 4 h 40 m for the card's return. This is not an eight-hour PASS or certification of all physical memory.
- Warm reload, resume, reset, passthrough reuse and repeated cold-boot reliability are not validated. Source replay is not a complete driver build or GSP simulation.

**Hardware tested on (if applicable):**
- GPU variant: CMP 170HX `10de:20c2`, GA100, FBPA/FBIO mask `0x00c0330c`, FBP mask `0x852`, observed dual-rank geometry.
- PCIe slot / host: BDF `0000:01:00.0`, Gen2 x4; x86_64 workstation with separate RTX A2000 display GPU. Exact physical slot designation not captured in retained summary.
- Kernel / OS: Ubuntu, `7.0.0-31-generic`; NVIDIA 610.43.02. Ubuntu 26.04.1 LTS for the fresh build/test.
