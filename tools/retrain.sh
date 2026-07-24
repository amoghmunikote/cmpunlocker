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

cur="$(nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
if [[ "${cur}" == "2" ]]; then
  echo "retrain: already Gen2; skip"
  exit 0
fi

python3 - <<'PY'
import os, mmap, struct, time, subprocess, glob

def sh(*args):
    return subprocess.check_output(args, text=True).strip()

def find_gpu():
    for path in sorted(glob.glob("/sys/bus/pci/devices/*/vendor")):
        dev = os.path.dirname(path)
        try:
            vend = open(path).read().strip()
            devid = open(os.path.join(dev, "device")).read().strip()
        except OSError:
            continue
        if vend != "0x10de":
            continue
        if devid in ("0x20c2", "0x2082") and os.path.exists(os.path.join(dev, "resource0")):
            return os.path.basename(dev)
    for path in sorted(glob.glob("/sys/bus/pci/devices/*/vendor")):
        dev = os.path.dirname(path)
        try:
            if open(path).read().strip() != "0x10de":
                continue
        except OSError:
            continue
        if os.path.exists(os.path.join(dev, "resource0")):
            return os.path.basename(dev)
    return None

def pci_bdf_short(bdf):
    return bdf.split(":", 1)[-1] if bdf.count(":") == 2 else bdf

def pci_read(dev, offset, width):
    fmt = {1: "b", 2: "w", 4: "l"}[width]
    return int(sh("setpci", "-s", pci_bdf_short(dev), f"{offset:x}.{fmt}"), 16)

def pci_write(dev, offset, width, val):
    fmt = {1: "b", 2: "w", 4: "l"}[width]
    subprocess.check_call(["setpci", "-s", pci_bdf_short(dev), f"{offset:x}.{fmt}={val:x}"])

def find_exp(dev):
    if not (pci_read(dev, 0x06, 2) & 0x10):
        return None
    ptr = pci_read(dev, 0x34, 1)
    while ptr and ptr != 0xFF:
        if pci_read(dev, ptr, 1) == 0x10:
            return ptr
        ptr = pci_read(dev, ptr + 1, 1)
    return None

def upstream_of(gpu_bdf):
    link = f"/sys/bus/pci/devices/{gpu_bdf}"
    parent = os.path.realpath(os.path.join(link, ".."))
    name = os.path.basename(parent)
    if name.startswith("0000:") or name.count(":") >= 1:
        return name
    return None

gpu = find_gpu()
if not gpu:
    print("retrain: no NVIDIA BAR0 device; skip")
    raise SystemExit(0)
up = upstream_of(gpu)
if not up:
    print(f"retrain: no upstream for {gpu}; skip")
    raise SystemExit(0)

res = f"/sys/bus/pci/devices/{gpu}/resource0"
fd = os.open(res, os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, os.path.getsize(res), access=mmap.ACCESS_WRITE)

def r(off):
    return struct.unpack_from("<I", m, off)[0]

def w(off, val):
    struct.pack_into("<I", m, off, val & 0xFFFFFFFF)

if r(0) == 0xFFFFFFFF:
    print("retrain: BAR0 dead; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)

w(0x8C2C0, r(0x8C2C0) & ~(1 << 2))
w(0x8C040, (r(0x8C040) & ~0xC0000) | (2 << 18))
w(0x8872C, 0x6)
time.sleep(0.05)
print(
    f"retrain: gpu={gpu} up={up} "
    f"CYA={r(0x8C2C0):08x} DIS_G2={(r(0x8C2C0)>>2)&1} "
    f"MAX={(r(0x8C040)>>18)&3} XVE={r(0x8872C):08x}"
)

for br in (up, gpu):
    cap = find_exp(br)
    if cap is None:
        continue
    ctl2 = pci_read(br, cap + 0x30, 2)
    pci_write(br, cap + 0x30, 2, (ctl2 & ~0xF) | 0x2)

cap = find_exp(up)
if cap is None:
    print("retrain: upstream has no PCIe cap; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)

ctl = pci_read(up, cap + 0x10, 2)
pci_write(up, cap + 0x10, 2, ctl | 0x20)
time.sleep(1.5)

bar0 = r(0)
if bar0 == 0xFFFFFFFF:
    print("retrain: WEDGED after retrain")
else:
    gcap = find_exp(gpu)
    sta = pci_read(gpu, gcap + 0x12, 2) if gcap is not None else 0
    print(f"retrain: bar0={bar0:08x} speed={sta & 0xF}")
m.close(); os.close(fd)
PY
