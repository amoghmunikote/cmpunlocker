# CMP 90HX benchmark results (unlocked vs locked)

Measured on CMP 90HX (`10de:220d`), driver 610.43.03 open kernel modules,
rejoin16 stockflow (compute + PCIe Gen2 unlocks active).
Locked numbers are a live A/B: the compute throttle was re-engaged and
disengaged in the same boot via the SS0/SS1 selectors.

## Compute (CUDA, `bench/bench2` — 8192³ GEMM + FMA issue rate)

| Benchmark            | Locked (stock CMP) | Unlocked | Speedup |
|----------------------|--------------------|----------|---------|
| FP32 FMA issue rate  |   0.72 TFLOP/s     | 18.78 TFLOP/s | ~26× |
| FP32 GEMM (CUDA)     |   0.72 TFLOP/s     | 18.15 TFLOP/s | ~25× |
| TF32 GEMM (tensor)   |   1.44 TFLOP/s     | 41.13 TFLOP/s | ~29× |
| FP16 in / FP32 acc   |   2.88 TFLOP/s     | 80.47 TFLOP/s | ~28× |
| FP16 in / FP16 acc   |   2.89 TFLOP/s     | 50.82 TFLOP/s | ~18× |

Locked state = 3.3% of peak issue rate (effective SM clock 56 MHz vs
1710 MHz rated). Unlocked = 85.8% of peak issue rate.

## PCIe host<->device bandwidth (`bench/cudabw`, pinned memory, 256 MiB xfers)

| Link state               | HtoD     | DtoH     |
|--------------------------|----------|----------|
| Gen1 x4 (stock fuse)     | ~1.0 GB/s* | ~1.0 GB/s* |
| **Gen2 x4 (this unlock)**| **1.7 GB/s** | **1.7 GB/s** |

\* Gen1 x4 theoretical max is 1.0 GB/s (2.5 GT/s, 8b/10b); the card was
verified at `2.5 GT/s PCIe` before the unlock. Gen2 x4 theoretical is
2.0 GB/s; measured 1.7 GB/s = ~85% efficiency. Note: once the unlock is
applied the card advertises Gen2 and will not train down to Gen1 again
(target-speed hints are overridden by the unlocked XVE config).

## VRAM internal bandwidth

673 GB/s DtoD (`bench/cudabw`, 512 MiB copies, read+write combined).
Not affected by either unlock (memory was never restricted on GA102).
