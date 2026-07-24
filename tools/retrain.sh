#!/bin/bash
set -euo pipefail

for _ in $(seq 1 60); do
  if nvidia-smi -L &>/dev/null; then
    break
  fi
  sleep 1
done
if ! nvidia-smi -L &>/dev/null; then
  echo "retrain: nvidia-smi not ready; skip"
  exit 0
fi

python3 - <<'PY'
import glob
import mmap
import os
import struct
import subprocess
import time


def sh(*args):
    return subprocess.check_output(args, text=True).strip()


def find_cmp_gpus():
    """Return every supported CMP 170HX that exposes BAR0."""
    gpus = []
    for path in sorted(glob.glob("/sys/bus/pci/devices/*/vendor")):
        dev = os.path.dirname(path)
        try:
            vendor = open(path).read().strip()
            device = open(os.path.join(dev, "device")).read().strip()
        except OSError:
            continue
        if (vendor == "0x10de" and device in ("0x20c2", "0x2082")
                and os.path.exists(os.path.join(dev, "resource0"))):
            gpus.append(os.path.basename(dev))
    return gpus


def pci_bdf_short(bdf):
    return bdf.split(":", 1)[-1] if bdf.count(":") == 2 else bdf


def pci_read(dev, offset, width):
    fmt = {1: "b", 2: "w", 4: "l"}[width]
    return int(sh("setpci", "-s", pci_bdf_short(dev), f"{offset:x}.{fmt}"), 16)


def pci_write(dev, offset, width, value):
    fmt = {1: "b", 2: "w", 4: "l"}[width]
    subprocess.check_call(
        ["setpci", "-s", pci_bdf_short(dev), f"{offset:x}.{fmt}={value:x}"]
    )


def find_exp(dev):
    """Find the PCIe capability, guarding against malformed capability lists."""
    if not (pci_read(dev, 0x06, 2) & 0x10):
        return None
    ptr = pci_read(dev, 0x34, 1)
    seen = set()
    while ptr and ptr != 0xFF and ptr not in seen:
        seen.add(ptr)
        if pci_read(dev, ptr, 1) == 0x10:
            return ptr
        ptr = pci_read(dev, ptr + 1, 1)
    return None


def upstream_of(gpu_bdf):
    parent = os.path.realpath(os.path.join("/sys/bus/pci/devices", gpu_bdf, ".."))
    name = os.path.basename(parent)
    if name.startswith("0000:") or name.count(":") >= 1:
        return name
    return None


def link_speed(dev, cap):
    return pci_read(dev, cap + 0x12, 2) & 0xF


def set_target_gen2(dev, cap):
    link_ctl2 = pci_read(dev, cap + 0x30, 2)
    pci_write(dev, cap + 0x30, 2, (link_ctl2 & ~0xF) | 0x2)


def retrain_gpu(gpu):
    gpu_cap = find_exp(gpu)
    if gpu_cap is None:
        print(f"retrain: gpu={gpu} has no PCIe capability; failed")
        return False

    before_speed = link_speed(gpu, gpu_cap)
    if before_speed >= 2:
        print(f"retrain: gpu={gpu} already Gen{before_speed}; skip")
        return True

    upstream = upstream_of(gpu)
    if not upstream:
        print(f"retrain: gpu={gpu} has no upstream PCI device; failed")
        return False

    fd = None
    bar0 = None
    try:
        resource = f"/sys/bus/pci/devices/{gpu}/resource0"
        fd = os.open(resource, os.O_RDWR | os.O_SYNC)
        bar0 = mmap.mmap(fd, os.path.getsize(resource), access=mmap.ACCESS_WRITE)

        def read32(offset):
            return struct.unpack_from("<I", bar0, offset)[0]

        def write32(offset, value):
            struct.pack_into("<I", bar0, offset, value & 0xFFFFFFFF)

        if read32(0) == 0xFFFFFFFF:
            print(f"retrain: gpu={gpu} BAR0 is unavailable; failed")
            return False

        write32(0x8C2C0, read32(0x8C2C0) & ~(1 << 2))
        write32(0x8C040, (read32(0x8C040) & ~0xC0000) | (2 << 18))
        write32(0x8872C, 0x6)
        time.sleep(0.05)

        for device in (upstream, gpu):
            cap = find_exp(device)
            if cap is not None:
                set_target_gen2(device, cap)

        upstream_cap = find_exp(upstream)
        if upstream_cap is None:
            print(f"retrain: gpu={gpu} upstream={upstream} has no PCIe capability; failed")
            return False

        link_ctl = pci_read(upstream, upstream_cap + 0x10, 2)
        pci_write(upstream, upstream_cap + 0x10, 2, link_ctl | 0x20)
        time.sleep(1.5)

        if read32(0) == 0xFFFFFFFF:
            print(f"retrain: gpu={gpu} wedged after retrain; failed")
            return False

        after_speed = link_speed(gpu, gpu_cap)
        print(
            f"retrain: gpu={gpu} upstream={upstream} "
            f"Gen{before_speed}->Gen{after_speed} "
            f"CYA={read32(0x8C2C0):08x} "
            f"MAX={(read32(0x8C040) >> 18) & 3} "
            f"XVE={read32(0x8872C):08x}"
        )
        return after_speed >= 2
    except (OSError, ValueError, struct.error, subprocess.CalledProcessError) as error:
        print(f"retrain: gpu={gpu} error: {error}")
        return False
    finally:
        if bar0 is not None:
            bar0.close()
        if fd is not None:
            os.close(fd)


gpus = find_cmp_gpus()
if not gpus:
    print("retrain: no supported CMP 170HX BAR0 device found; skip")
    raise SystemExit(0)

failed = 0
for gpu in gpus:
    if not retrain_gpu(gpu):
        failed += 1

if failed:
    print(f"retrain: {failed}/{len(gpus)} GPU(s) failed")
    raise SystemExit(1)

print(f"retrain: all {len(gpus)} supported GPU(s) are Gen2 or retrained successfully")
PY
