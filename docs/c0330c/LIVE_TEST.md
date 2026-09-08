# Build and live-test handoff for the C0330C PR

Run from the complete current working checkout on the Ubuntu workstation,
including the uncommitted patch, constants/build changes and tests. A fresh
clone of upstream alone does not contain this experiment. Preserve `.git` so
that the build receipt records the base commit; the input manifest identifies
the actual uncommitted build inputs.

## First gate: build without installation

Requires Linux x86_64 running `7.0.0-31-generic`, matching kernel headers,
Python 3.12+, PyYAML, GNU patch, Git, a C compiler with ASan/UBSan, GCC, make,
and modinfo. The script does not install missing prerequisites. NVIDIA source
is pinned to `610.43.02` and a known SHA-256. It does not need the GPU to build.

From the checkout, as the normal user without sudo:

```sh
mkdir -p "$HOME/cmp-pr-builds"
python3 -B tests/c0330c/build-only.py --output-parent "$HOME/cmp-pr-builds"
```

It prints a fresh build directory. During compilation, output goes to that
folder's `build.log`; follow it from another terminal if desired. Keep the
whole directory. Required success is `BUILD_ONLY_PASS` in `result.json`, all
five module hashes/vermagic values, and the build log. Review warnings even
when compilation succeeds. Interrupted or failed runs cannot report a pass.
The script never calls `driver/build.sh`, installs modules, rebuilds initramfs,
loads/unloads drivers, changes services, accesses GPU registers or runs a GPU
workload. Do not substitute the upstream build/install script.

The snapshot in `inputs/` and `INPUT_SHA256SUMS` identifies exactly what was
built. Its base Git commit is insufficient by itself while changes remain
uncommitted. If build inputs change later, rebuild rather than reuse evidence.

## Source preparation already checked locally

On 2026-09-08, `--prepare-only` passed with GNU patch 2.8, the checksum-pinned
610.43.02 archive and 157 scenarios / 14,662 assertions under ASan/UBSan.
This mode intentionally does not compile Linux modules. The normal build mode
refuses macOS. The actual Linux build subsequently passed; see [build evidence](BUILD_VALIDATION.md). Installation, reboot checks, and fresh smoke/near-full tests subsequently passed; see [hardware evidence](HARDWARE_VALIDATION.md).

## Subsequent live gates

Before installing, confirm the original C0330C card is still present, physical
recovery access and working cooling, the user-space driver version, both GPU
identities, and a matched known-good module/initramfs recovery set. Prepare a
separate reviewed installation procedure that does not attempt a warm reload.
Use a full power cycle and check all four C0330C checkpoint messages.

Bind the memory-test harness to the new build receipt only after reviewing the
installed and loaded candidate identity. The historical personal test harness
requires the old module SHA-256
`3975f5fd6226cc9c7c9e58ce1b31744b83d40f3ff398bf448828749294d19b63`;
it must not be used by weakening or skipping that check. Module srcversion
alone previously failed to distinguish candidate bytes from other builds.
New installation evidence and boot logs must accompany the file hashes.

The harness also binds BDF, UUID, kernel, test binary/source manifest and
same-boot qualification. Old smoke/qualification results cannot authorize
new-module tests. Keep the old bundle/results intact; prepare a separate
candidate-bound bundle after the build. Sequence: fresh 512 MiB smoke,
near-full readback, repeat after another cold boot, then sustained testing.
Record each stage separately. No stage is automatically started by this build.

The fresh separate bundle was pinned to the new module hash and passed smoke
and near-full readback on 2026-09-08. Repeated cold boots and sustained testing
remain open; the observed reboot was not recorded as a full power cycle.
