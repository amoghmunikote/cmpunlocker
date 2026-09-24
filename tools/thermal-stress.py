#!/usr/bin/env python3
"""Sustained SM + HBM load on one GPU, for thermal characterisation.

Alternates back-to-back bf16 GEMMs (tensor-core power draw) with sweeps over a
large resident buffer (HBM traffic), so the die and the memory stacks both heat
up rather than only one of them. One process per GPU; see thermal-stress.sh,
which drives these and owns the temperature abort.

Reports achieved bf16 throughput so a thermally limited run is distinguishable
from a healthy one at the same temperature.
"""
import argparse
import time

import torch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", type=int, help="CUDA device index")
    parser.add_argument("duration", type=float, help="seconds to sustain load")
    parser.add_argument("--matrix", type=int, default=8192,
                        help="GEMM dimension (default: 8192)")
    parser.add_argument("--sweep-gib", type=int, default=12,
                        help="resident buffer swept for HBM traffic (default: 12)")
    args = parser.parse_args()

    torch.cuda.set_device(args.device)
    dev = f"cuda:{args.device}"
    n = args.matrix

    a = torch.randn(n, n, dtype=torch.bfloat16, device=dev)
    b = torch.randn(n, n, dtype=torch.bfloat16, device=dev)
    c = torch.empty(n, n, dtype=torch.bfloat16, device=dev)
    sweep = torch.ones(args.sweep_gib * 1024 ** 3 // 2, dtype=torch.bfloat16, device=dev)

    torch.cuda.synchronize(args.device)
    start = time.time()
    gemms = 0
    sweeps = 0

    while time.time() - start < args.duration:
        # Keep the queue saturated between syncs, or the sync cost shows up as
        # idle time on the GPU and the card runs cooler than the load implies.
        for _ in range(40):
            torch.matmul(a, b, out=c)
        gemms += 40
        for _ in range(3):
            sweep.mul_(1.0001)
        sweeps += 3
        torch.cuda.synchronize(args.device)

    elapsed = time.time() - start
    tflops = 2 * n ** 3 * gemms / elapsed / 1e12
    bandwidth = sweeps * args.sweep_gib * 2 / elapsed
    print(f"GPU{args.device}: {elapsed:.0f}s, {gemms} GEMMs ({tflops:.1f} TFLOP/s bf16), "
          f"{sweeps} sweeps of {args.sweep_gib} GiB ({bandwidth:.0f} GiB/s r+w)",
          flush=True)


if __name__ == "__main__":
    main()
