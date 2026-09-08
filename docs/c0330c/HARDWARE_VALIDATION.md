# Fresh PR hardware validation — 2026-09-08

The snapshotted PR integration based on `76f0954` was installed and tested on
the original C0330C CMP 170HX with NVIDIA 610.43.02, Ubuntu 26.04.1 LTS,
kernel `7.0.0-31-generic`, and a separate RTX A2000 display GPU.
Build inputs and hashes are recorded in [BUILD_VALIDATION.md](BUILD_VALIDATION.md).

After installation, all five installed module hashes matched the build receipt.
After the operator reboot, the boot ID changed and the loaded driver reported
the fresh build timestamp (2026-09-08 07:17:59 EDT). All four C0330C geometry
checkpoints passed. The CMP reported 65536 MiB at PCIe Gen2 x4; both GPUs were
present and idle. No Xid or PCIe faults were found in the preflight journal,
and the monitored endpoint/bridge AER counters were zero.
This was an observed reboot, not a documented power-off/cold-boot test.

The test bundle was separately pinned to the fresh nvidia.ko SHA-256
`b15832a9fe42020e6eee04261f5427a9b4e2f998432d27e6bb17dd64c87b09f4`.
Its Linux executable passed CPU-only self-tests before GPU testing.

| Stage | Data checked per pass | Full readback passes | Mismatches | Monitor errors | Elapsed |
| --- | --- | --- | --- | --- | --- |
| Smoke | 512 MiB | 2 | 0 | 0 | 7.357 s |
| Near-full | 62.625 GiB (67,243,081,728 bytes) | 2 | 0 | 0 | 92.605 s |

Both stages completed with `STAGE_PASS` and child exit code 0. These are fresh
results for this PR build, separate from the earlier candidate's sustained run.
The unchanged test uses globally address-derived complementary patterns and
full CPU readback, with a separate 256 MiB scratch allocation for cache pressure.
Scratch and driver/context headroom are excluded from the verified-data total.

Retrieved supervisor receipts: [smoke](fresh-smoke-result.json) and
[near-full](fresh-full-result.json). Detailed logs remain in the workstation's
separate test bundle; the attached JSON files are summary receipts.

This supports 62.625 GiB of successfully tested usable allocation on this card.
It does not certify all physical 64 GiB: reserved memory was not tested and
physical address placement/highest-address coverage remains unknown. The
receipts correctly retain `hardware_capacity_validated: false`. No extended
soak or repeated cold-boot test has completed for this fresh build. Warm reload,
resume, reset, passthrough reuse, other cards, and newer NVIDIA versions remain
unvalidated on hardware. Keep this support experimental.
