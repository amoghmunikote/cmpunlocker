# C0330C PR build validation — 2026-09-08

The exact snapshotted PR inputs built successfully as the normal user on
Ubuntu 26.04.1 LTS, x86_64, kernel `7.0.0-31-generic`, using NVIDIA 610.43.02.
All 13 patches applied with zero fuzz; 157 scenarios / 14,662 assertions passed
under ASan/UBSan on Ubuntu. All five modules passed version/vermagic checks.
The final receipt reports `BUILD_ONLY_PASS`. No modules were installed or
reloaded, and no GPU workload was started by this procedure.

The original C0330C card is still present. The existing installed nvidia.ko
hash before this build matched the earlier hardware-tested candidate. This
build success does not establish live behavior of the newly built modules.

## Identities

- Base commit: `76f0954fbb9864df0938f9c7bd9bfdc5bf2d6636`.
- Build-input manifest SHA-256: `7e87d990878d21be2b7861922097f00514b7577c990151dd9d1352bff77cf9c9`.
- Patched kernel_gsp.c SHA-256: `972734fd786c274f319828c2a4e766d51061cb180b63a60b3a774912d4d91545`.
- New nvidia.ko SHA-256: `b15832a9fe42020e6eee04261f5427a9b4e2f998432d27e6bb17dd64c87b09f4`.
- Build-log SHA-256: `172107986d9b224b75f042f725b2dcf43746b4c6f4bbda9c4507bc7427c70c3b`.

The base commit alone does not identify the uncommitted changes. The saved
input manifest and snapshot do. The [original input manifest](INPUT_SHA256SUMS)
and [build receipt](build-result.json) are attached. The receipt contains all five
module hashes; its input-manifest and build-log hashes matched the retrieved artifacts.

PR preparation rechecked all 26 code, configuration and test files in the
manifest against this checkout: every hash matched. The original transfer also
included four macOS AppleDouble metadata files (`tests/c0330c/._*`), which the
manifest retains for receipt integrity. Those metadata files are absent from
this PR and are not source inputs to the compiler or test runner.

## Warnings and limits

The build is not warning-free: 13,750 objtool naked-return warnings in a
MITIGATION_RETHUNK build, 223 objtool frame-pointer warnings, one unused devId
warning and one compiler-identity warning. BTF generation was skipped because
vmlinux was unavailable. These warnings have not been established harmless
by this successful compilation. Installation acceptance, loaded-module
identity, cold-boot geometry checks and memory integrity remain separate gates.

## Subsequent live acceptance

The built modules were subsequently installed and tested after reboot. Fresh
smoke and 62.625 GiB near-full readback passed; see
[hardware validation](HARDWARE_VALIDATION.md). The build-only receipt remains
unchanged because it records the state at build completion.
