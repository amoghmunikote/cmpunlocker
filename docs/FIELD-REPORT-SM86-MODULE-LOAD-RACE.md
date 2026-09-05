# sm_86 (RTX 3090): triton kernel module-load spins or Xid 31 under the cmpunlocker-patched 610.43.03 driver in multi-GPU engine context

## Environment

- 2× RTX 3090 24GB (sm_86, stock) + 2× CMP 170HX (sm_80, 40/64GB, unlocked via cmpunlocker v0.3 / f51da03 — includes the PR #32 WPR2 late-pma fix)
- Driver 610.43.03: cmpunlocker-patched **kernel modules** (sec2-postbl-plm-ss-cfg + late-pma + bar1 + gen2 patches, mixed profile); userspace (incl. `libcuda.so`) is the stock 610.43.03 build; kernel 7.0.0-27-generic
- Workload: vLLM (recent fork), pipeline parallelism across all 4 GPUs, bf16, CUDA graphs on, triton 3.x JIT kernels, Python 3.12
- The 3090s host pipeline rank 0; the 170HX cards host later ranks

## Summary

**First-use triton kernel module-loads on the 3090s (sm_86) are a lottery under the patched driver stack**: the same load path inside stock `libcuda` either (a) completes in ~2s as normal, (b) busy-spins forever inside libcuda at 100% SM, or (c) crashes the engine with Xid 31. The sm_80 (170HX) ranks load the *same kernels* near-instantly and never exhibit any of the three. We saw this across ~90 engine restarts over four days of debugging a vLLM pipeline; it is the single remaining blocker for mixed sm_86 + unlocked sm_80 rigs.

To be clear on classification: this is **not** the WPR2/late-pma allocation class fixed by PR #32 (we carry that fix; the signature is entirely different — no pool-exhaustion pattern, fault VA fixed across process lifetimes, pure first-use-load timing).

## Three incident classes, one signature

All three end in the same frame chain — `triton CompiledKernel._init_handles → cuModuleLoadData` — inside the stock userspace `libcuda.so.610.43.03`:

**1. Infinite spin (most common).** First launch of a newly-specialized kernel on the 3090 rank never returns. `py-spy dump --native` shows ~11 anonymous frames inside libcuda under `cuModuleLoadData`; the GPU sits at 100% SM / max clocks; dmesg clean, no Xid; the other ranks idle in their NCCL receives. Frozen across dumps minutes apart — a livelock, not slow compile.

**2. Xid 31 storm.** Over one night (~60 engine restarts), every boot was healthy until the *first inference request*, then:
`NVRM: Xid 31 ... MMU Fault FAULT_PDE VIRT_READ @ 0x11_00870000` on the 3090 at PCI 0000:04:00 — **the identical fault VA in all ~60 occurrences across different processes and restarts**, always in the same kernel-launch path (`postprocess_state → _init_handles` in our case). A fixed VA across process lifetimes points at a deterministic bad-pointer path in the module-load/JIT machinery, not flaky hardware.

**3. ~300s stalls that look like hangs.** Before we raised RPC timeouts, first-use loads on the 3090 frequently took ~300s (sometimes completing, sometimes being killed by a 300s watchdog). This is how the disease first presented — as "random" multi-minute latency spikes on the first request after boot.

## What we ruled out (isolation probes)

- **The kernels themselves**: compiled + loaded + ran the exact crashing triton kernel standalone on an idle 3090 (same driver, same host) in **~2s** — including under a 4GB expandable-segments VMM allocation. Kernel, silicon, and VMM are individually fine.
- **Triton cache corruption / cross-arch poisoning**: per-rank `TRITON_CACHE_DIR` and fresh cache volumes did not change behavior. Cache-*hit* loads also spin, so this is not a compile-path issue.
- **The vLLM layer**: pure-torch rewrites of the affected kernels served correctly; the disease simply moved to the next first-use triton kernel.
- **Hardware**: zero Xids or spins on the 170HX ranks under identical traffic; the fault VA repetition (class 2) is software-shaped.

## Trigger conditions (as far as we can tell)

- Only on sm_86 cards under the patched stack; sm_80 ranks (same host, same traffic) are immune.
- Only on **first module-load of a kernel specialization within a process** (loads, not just compiles — cached cubins re-roll every process start).
- Outcome is **near-deterministic per (kernel, specialization shape)** — a given shape either always wins or always loses across restarts — but we cannot predict winners from the outside.
- The standalone probe loads in 2s while the identical shape hangs inside the full engine: the race appears to need engine context (multi-rank pipeline + CUDA graphs + our CPU-offload worker process) or concurrent GPU activity on the card.

## Workarounds we shipped (all effective, all empirical)

1. **Boot-time warmup**: run the full kernel warmup at engine start (paying all first-use loads at boot, where a restart loop can converge) instead of on first request.
2. **Shape-space collapse**: demote depth-dependent specialization keys (page-table widths) from `tl.constexpr` to `do_not_specialize` runtime args, so one cubin serves all inputs — dramatically fewer first-use loads.
3. **Warmup battery**: fire a few varied-length requests right after every engine (re)start (systemd unit watching container events) to cover shapes boot warmup can't reach.

With those three, our 262K-context lane is stable including cold restarts — but every new kernel family re-rolls the dice, which is why we think this is worth a driver-side look.

## Ask

Could the sm_86 module-load path be re-checked for an interaction between stock userspace libcuda and the patched kernel state — particularly `cuModuleLoadData` behavior under concurrent contexts/graphs on cards that share the host with unlocked 170HXs? We're happy to attach full `py-spy --native` dumps, the Xid logs, or a minimal engine-context reproducer if useful. The unlock itself has been rock-solid (64GB + 40GB, months of stable serving) — this is the only instability we've hit that correlates with the patched stack.
