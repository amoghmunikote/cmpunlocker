#!/bin/bash
set -euo pipefail

for _ in $(seq 1 90); do
  if nvidia-smi -L &>/dev/null; then
    break
  fi
  sleep 1
done
if ! nvidia-smi -L &>/dev/null; then
  echo "retrain: nvidia-smi not ready; skip"
  exit 0
fi

mem="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
if [[ -z "${mem}" || "${mem}" == "[N/A]" ]]; then
  echo "retrain: GPU memory not ready; skip"
  exit 0
fi

cur="$(nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
max="$(nvidia-smi --query-gpu=pcie.link.gen.max --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
if [[ "${cur}" == "2" ]]; then
  echo "retrain: already Gen2; skip"
  exit 0
fi
if [[ "${max}" != "2" && "${max}" != "3" && "${max}" != "4" ]]; then
  echo "retrain: Device Max=${max} (need >=2); skip"
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
        if vend == "0x10de" and devid in ("0x20c2", "0x2082"):
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
    st = pci_read(dev, 0x06, 2)
    if st == 0xFFFF or not (st & 0x10):
        return None
    ptr = pci_read(dev, 0x34, 1)
    while ptr and ptr != 0xFF:
        if pci_read(dev, ptr, 1) == 0x10:
            return ptr
        ptr = pci_read(dev, ptr + 1, 1)
    return None

def upstream_of(gpu_bdf):
    parent = os.path.realpath(os.path.join(f"/sys/bus/pci/devices/{gpu_bdf}", ".."))
    name = os.path.basename(parent)
    if name.startswith("0000:") or name.count(":") >= 1:
        return name
    return None

gpu = find_gpu()
if not gpu:
    print("retrain: no GPU; skip")
    raise SystemExit(0)
up = upstream_of(gpu)
if not up:
    print("retrain: no upstream; skip")
    raise SystemExit(0)

res = f"/sys/bus/pci/devices/{gpu}/resource0"
fd = os.open(res, os.O_RDWR | os.O_SYNC)
size = os.path.getsize(res)
m = mmap.mmap(fd, size, access=mmap.ACCESS_WRITE)

def r(off):
    return struct.unpack_from("<I", m, off)[0]

def w(off, val):
    struct.pack_into("<I", m, off, val & 0xFFFFFFFF)

if r(0) == 0xFFFFFFFF or r(0x8C2C0) == 0xFFFFFFFF or r(0x88084) == 0xFFFFFFFF:
    print("retrain: BAR0 not live; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)

cap = r(0x88084)
if (cap & 0xF) < 2:
    print(f"retrain: Cap still Gen{cap & 0xF} (0x{cap:08x}); skip")
    m.close(); os.close(fd)
    raise SystemExit(0)

w(0x8C2C0, r(0x8C2C0) & ~(1 << 2))
w(0x8C040, (r(0x8C040) & ~0xC0000) | (2 << 18))
time.sleep(0.05)

cya = r(0x8C2C0)
mx = (r(0x8C040) >> 18) & 3
xve = r(0x8872C)
dis_g2 = (cya >> 2) & 1
print(
    f"retrain: gpu={gpu} up={up} "
    f"CYA={cya:08x} DIS_G2={dis_g2} MAX={mx} XVE={xve:08x} CAP={r(0x88084):08x}"
)

if r(0) == 0xFFFFFFFF or dis_g2 != 0 or mx != 2:
    print("retrain: preconditions failed; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)

ug = find_exp(up)
gg = find_exp(gpu)
if ug is None or gg is None:
    print(f"retrain: missing PCIe cap up={ug} gpu={gg}; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)

for br, capoff in ((up, ug), (gpu, gg)):
    ctl2 = pci_read(br, capoff + 0x30, 2)
    pci_write(br, capoff + 0x30, 2, (ctl2 & ~0xF) | 0x2)

ctl = pci_read(up, ug + 0x10, 2)
pci_write(up, ug + 0x10, 2, ctl | 0x20)
time.sleep(2.0)

if r(0) == 0xFFFFFFFF:
    print("retrain: WEDGED after retrain")
else:
    sta = pci_read(gpu, gg + 0x12, 2)
    print(f"retrain: speed_after={sta & 0xF}")
m.close(); os.close(fd)
PY
