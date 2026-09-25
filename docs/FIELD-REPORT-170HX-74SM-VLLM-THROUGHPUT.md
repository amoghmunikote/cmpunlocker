# Field report: dual CMP 170HX (10de:20c2) at 74 SM with PR #55, production vLLM throughput

> Measured 2026-09-25 on our dual-card workstation. All numbers below are readings
> from that machine, not estimates. Where a number cannot be attributed to the
> +4 SM change, we say so explicitly.

## Summary

- Two CMP 170HX cards (device id `10de:20c2`, 8 GB SKU, unlocked to 64 GB) went from
  **70 SM → 74 SM on both cards** after upgrading cmpunlocker `a3ea84b` (2026-09-06)
  → **`6c442ee`** (PR #55, merged 2026-09-25 11:09 +08).
- driver **610.43.02**, PCIe **Gen2**, `verify.sh` → `[OK]`, **65536 MiB** per card,
  **zero Xid** after the reboot (plain `reboot`, see *Upgrade procedure*).
- Production workload on one card: **vLLM 0.28.0 + MTP(5) / Qwen3.8-27B-FP8, 262144 ctx**
  → steady-state 512-token decode **≈79 tok/s (76–92 across 4 warm rounds)**.
- **Gotcha worth copying**: vLLM `torch.compile` caches are keyed by SM count — after the
  upgrade every user's `~/.cache/vllm` (including `root`'s, if a service runs as root)
  must be cleared or vLLM crash-loops. Details in *Pitfalls*.

## System under test

| Item | Value |
|---|---|
| Host | HP Z8 G4, 1400 W PSU, Secure Boot disabled |
| Cards | 2 × CMP 170HX, PCI id `10de:20c2` (8 GB SKU), 64 GB after unlock |
| Driver | NVIDIA open kernel modules **610.43.02** (`apt-mark showhold`: 26 packages) |
| Unlock tool | cmpunlocker @ `6c442ee` (PR #55 "Add +4 more SMs") |
| Link | PCIe Gen2 (software-gen2 already in master) |
| Cooling | Blower + duct (card is passively cooled from the factory) |

Post-upgrade verification (after the reboot, then `verify.sh`):

```
verify.sh                        -> [OK]
nvidia-smi                       -> 2 cards, 65536 MiB each, Gen2
SM count                         -> 70 -> 74 on both cards
dmesg Xid                        -> none
```

Independent SM-count check, no torch needed (pure CUDA):

```c
// smcheck.cu
#include <cstdio>
int main(){
  int n=0; cudaGetDeviceCount(&n);
  for(int i=0;i<n;i++){
    cudaDeviceProp p; cudaGetDeviceProperties(&p,i);
    printf("GPU%d: %s SMs=%d CC=%d.%d VRAM=%.1fGB\n",
           i, p.name, p.multiProcessorCount, p.major, p.minor,
           p.totalGlobalMem/1073741824.0);
  }
  return 0;
}
```

```
nvcc -o smcheck smcheck.cu && ./smcheck
GPU0: NVIDIA CMP 170HX SMs=74 CC=8.0 VRAM=63.4GB
GPU1: NVIDIA CMP 170HX SMs=74 CC=8.0 VRAM=63.4GB
```

## Upgrade procedure that worked

1. `verify.sh` pre-check on the old tree, services stopped, VRAM drained.
2. `git checkout 6c442ee` (from `a3ea84b`), confirm the driver version whitelist still
   contains 610.43.02.
3. `install.sh --profile=8gb --no-gen2-service` → 5 `.ko` + new `cmp_no_bus_reset.ko`,
   `depmod` + initramfs rebuild OK.
4. **Hot reload does not apply the new SEC2/PLM path** — it fails as expected, so the
   modules must be restarted at boot. The installer prints
   `Cold reboot recommended: sudo shutdown -h now  (then power on)`, but
   **in our run a plain `reboot` over SSH was enough — no physical power cycle was
   needed** (we verified this the same day: unlock took effect right after that reboot).
   The old modules keep running until the restart, so services can stay up during the
   window.
5. After that reboot: `verify.sh` → `[OK]`, SM counts re-checked, `Xid` checked,
   services brought back up and a smoke inference run performed.

## Production benchmark (74 SM state)

Configuration: vLLM **0.28.0** + MTP(5) / **Qwen3.8-27B-FP8**, TP=1, seqs=4,
262144 ctx, temp=0.3, GPU-memory-utilization 0.85, on one card.
The card is a **shared production card**, not an idle one: the sibling card was running
another inference service (~35% util) plus a diffusion UI, and this card served multiple
consumers. Ambient cooling uncontrolled; sampled at **84 °C / 1395 MHz / 79 W**.

| Measurement | Result | Note |
|---|---|---|
| 512-token decode throughput, 5 rounds | 15.9 / 92.0 / 77.0 / 81.2 / 76.5 tok/s | round 1 is a cold start and is discarded; warm 4-round **median ≈79 tok/s**, range 76–92 |
| Idle-ish card compute (sibling card, still partly loaded) | FP16 185 T / BF16 185 T / FP32 12.5 T, HBM **1599 GB/s** | lower bound, not a clean-idle reading |
| This card under 27B service (55 GB resident) | FP16 64.7 T / BF16 63.8 T / FP32 4.9 T, HBM **928 GB/s** | depressed by the resident model, lower bound |

### What this data does *not* show (read this before quoting it)

- **There is no same-condition 70 SM control arm** — we deliberately did not revert the
  cards, so **the +4 SM increment cannot be attributed from these numbers**.
- Older numbers from 2026-08-20 (91–103 tok/s) came from **vLLM 0.27.1 + 70 SM**; the
  version mix makes them **not a valid comparison**, and the difference must not be
  attributed to SM count.
- The only claim supported here: *in the 74 SM state, this production service sits at
  ≈79 tok/s steady state (512-token decode), works correctly, and raises no Xid.*

## Pitfalls hit during the upgrade

0. **Hot reload does not pick up the new SEC2/PLM patch** — expect it to fail; restart
   the modules at boot. Upstream *recommends* a cold reboot (`sudo shutdown -h now`
   then power on); a plain SSH `reboot` was sufficient on our machine.
1. **vLLM `torch.compile` cache is keyed by SM count.** After 70 → 74, cached artifacts
   fail an assertion (`expected size 74==70`) and vLLM crash-loops
   (`NRestarts=14`). Clear **every** user's cache, not just the shell user's:
   ```
   rm -rf ~/.cache/vllm/torch_compile_cache
   rm -rf /root/.cache/vllm/            # if the service unit has no User=, it runs as root
   ```
   We cleared the wrong user first and the root-run service kept crash-looping —
   check `systemctl show <unit> -p User` before clearing.
2. **`chattr +i` on the module metadata files blocks `build.sh`.** If the immutability
   bit was set for protection, `lsattr` first, `chattr -i`, install, then set it back.
3. **`install.sh` removes the NVIDIA DKMS modules.** After any kernel upgrade the
   unlocker install must be re-run (this is printed at the end of the install log);
   it does not conflict with holding the driver packages.
4. **Known-benign noise**: one card logs `Booter failed (0x31)` a few times at startup;
   GSP initializes normally afterwards, no Xid, no functional impact.

## Caveats / status of neighbouring work

- Copilot's review on PR #55 flagged the unvalidated `0xff` GPC-override write as *high*;
  treat the change as aggressive and watch community soak results before relying on it.
- Per-card recovered SM count depends on how many TPCs were disabled/fused off on that
  particular card — the README's advice (check the real number after a cold boot) holds;
  our two cards both landed on 74.
- ECC: the SM/SRAM side can be enabled, HBM ECC is fuse-locked (upstream PR #56,
  currently shelved).
