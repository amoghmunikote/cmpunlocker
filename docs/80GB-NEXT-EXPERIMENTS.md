# 10GB → 80GiB: next isolation experiments

This note proposes a narrow next-step test sequence for the experimental `10de:2082` 80GiB path.
It does **not** claim that generic 80GiB CUDA support works, and it does not change any unlock code.

Current evidence from the four-card report supports three separate statements:

- coherent 80GiB geometry can boot;
- device-side tagged data can survive through roughly 75–76GiB without folding;
- ordinary bulk H2D population and large-allocation teardown remain unstable.

Primary report: https://gist.github.com/cuddylac997/c3d80faa2430e3650cd934eda5fd65a9

The immediate goal is to isolate which variable actually trips the recurring GSP failure before changing more geometry or capacity constants.

## 0. Reproduce on the current baseline first

The four-card report predates the Aug. 30 WPR2/high-reserved-region correction. That bug is documented as a different failure class, so this is not a claim that it fixes 80GiB. However, the H2D and teardown minimal reproducers should first be rerun on a commit containing that correction (current master while drafting this note: `76f0954`) before treating older exact behavior as the current baseline.

Record the exact driver/module commit, GSP image hash, kernel, card identity and cold-boot state for every run.

## 1. Re-check the H2D threshold interpretation

In the published `hbmh2d.cu`, all payload allocations are created before the copy loop begins.
In the 300 × 256MiB case, roughly 75GiB is already allocated before the first H2D transfer.

That reproducer therefore proves failure during copy progress in a high-allocation state, but does not independently isolate:

- total allocated framebuffer;
- cumulative transferred bytes;
- destination traversal/address;
- elapsed operation count;
- pageable versus pinned source memory.
A 40GiB-derived internal bound remains plausible, but this test does not uniquely establish it.
The failed low-VRAM staging test also remains a valid negative result, but allocation order and a CUDA virtual pointer do not prove physical placement of the staging pages.

## 2. Separate allocation state from transfer progress

Run three matched cases with the same transfer size and verification pattern:

1. Small working set: allocate 1–4GiB and repeatedly overwrite one destination until cumulative H2D traffic exceeds 80–100GiB.
2. Large background: allocate roughly 72–75GiB, leave most of it untouched, and repeat the same traffic into one small destination.
3. Destination sweep: run the existing style of copy across many allocations.

If case 1 survives but case 2 fails, high-memory-conditioned RM/GSP state becomes much stronger evidence.
If both fail after similar cumulative traffic, allocation total cannot explain the whole failure.

Repeat the large-background case at approximately 32, 36, 40, 44, 48, 56, 64 and 72GiB while keeping copy size/count fixed.

Also change only destination traversal:

- forward;
- reverse;
- deterministic shuffle;
- one fixed allocation repeatedly.

A failure that follows a particular allocation/region is materially different from one that follows cumulative bytes or time.

## 3. Compare pageable and pinned H2D
With identical device allocation state and payload contents, compare:

1. pageable host memory + `cudaMemcpy`;
2. page-locked host memory from `cudaHostAlloc` + `cudaMemcpy`.

This checks whether source registration/staging changes the result before assigning the failure to one copy-engine mechanism.

## 4. Try mapped host memory → SM-driven population

This is the most distinct workaround experiment to try next.

Instead of:

```text
host RAM -> cudaMemcpy H2D -> HBM
```

use:

```text
cudaHostAllocMapped host buffer
    -> GPU kernel reads mapped host memory over PCIe
    -> GPU kernel writes target HBM
```

Use `cudaHostAllocMapped` / `cudaHostGetDevicePointer` (or the equivalent mapped page-locked path) and a simple vectorized CUDA copy/verify kernel.
The matched control must use the **same pinned host allocation** with ordinary `cudaMemcpy`.

Interpret the outcomes narrowly:
- pageable memcpy fails, pinned memcpy works: investigate host-memory registration/staging;
- both memcpy paths fail, mapped-host/SM copy works: candidate alternate payload-loading path;
- mapped-host/SM copy also fails: the problem is broader than the explicit bulk H2D payload copy.

This differs from the already-failed VRAM staging experiment because no ordinary bulk H2D payload copy occurs before the SM reads the source.
It still uses PCIe, CUDA mappings and driver/GSP state, so success is not assumed.

## 5. Check small transfers explicitly after high allocation

After allocating roughly 72–75GiB, run fully checked H2D and D2H transfers at several sizes, for example:

- 4B, 8B and 64B;
- 4KiB and 64KiB;
- 1MiB;
- 16MiB;
- 256MiB.

Repeat each enough times to distinguish immediate size dependence from cumulative traffic/state.
This matters for a workload-specific path where weights load before high allocation and only GPU-generated KV/cache pushes residency over 40GiB.

## 6. Map the recurring GSP PC before guessing at a fix

The report repeatedly observes GSP PC `0x5b2ba28`.
Map that address against the **exact firmware image used by the reproducer**, recording image hash and relocation context.
Then identify the routine, caller and object being accessed before modifying a capacity-derived bound.

In parallel, compare supported 40GiB and coherent 80GiB initialization for framebuffer-derived GSP/RM state:
- framebuffer length fields;
- PMA/FB region descriptors and counts;
- CE/channel/mapping objects;
- RPC payloads/descriptors;
- page-table/layout metadata;
- GSP heap/WPR/bootstrap sizing and clamps.

The NVIDIA open modules contain framebuffer-derived GSP heap sizing (`_kgspCalculateFwHeapSize` / `kgspGetFwHeapSize_IMPL`), which is worth instrumenting as a comparison point.
That is a lead, **not evidence that the heap is undersized**. The current unlock path already repopulates WPR metadata after geometry writes.

## 7. Keep teardown as a separate reproducer

After a clean >40GiB device-kernel fill/verify, vary one thing at a time:

- free one allocation versus many;
- forward versus reverse free order;
- synchronize before `cudaFree()`;
- destroy the CUDA context without explicit frees;
- normal process exit;
- repeated context create/destroy.

`_exit()` can isolate teardown but should not count as a production fix.

## 8. Workload-specific experiment if generic H2D remains broken

For a model whose bulk weights fit below 40GiB:

1. load all large host-originating tensors while total allocation is comfortably below the failure regime;
2. initialize the runtime;
3. allocate additional HBM for KV/cache/state;
4. let GPU compute populate that additional state;
5. trace every host-to-device transfer after crossing the high-allocation threshold;
6. test 48, 56, 64 and 72GiB total residency with repeated long-context cycles.

If this works, label it **specialized >40GiB device-generated state**, not generic 80GiB CUDA support.

## 9. Suggested pass bar

A generic 80GiB milestone should eventually demonstrate:

- coherent boot;
- correctness throughout usable upper HBM;
- substantial H2D while >40GiB is already allocated;
- repeated allocation/free cycles;
- repeated CUDA contexts/processes;
- real model residency/use above 40GiB;
- soak without Xid/device loss;
- reload/restart without a cold power cycle where expected;
- reproduction on more than one `2082`.

The immediate next milestone is narrower:

> Isolate what variable actually trips the recurring GSP failure, and determine whether mapped-host → SM-driven population survives where ordinary H2D does not.

Until then, 40GiB remains the supported `2082` configuration and 80GiB remains experimental.
