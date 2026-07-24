#!/bin/bash
set -euo pipefail

SYS=/sys/bus/pci/devices/0000:0a:00.0
for i in $(seq 1 120); do
  if [[ -e $SYS/resource0 ]] && nvidia-smi -L &>/dev/null; then
    break
  fi
  sleep 1
done
if ! nvidia-smi -L &>/dev/null; then
  echo "retrain: not ready; skip"
  exit 0
fi

mem="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || true)"
if [[ -z "${mem}" || "${mem}" == "[N/A]" ]]; then
  echo "retrain: memory not ready; skip"
  exit 0
fi

cur="$(nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)"
if [[ "${cur}" == "2" ]]; then
  echo "retrain: already Gen2; skip"
  exit 0
fi

max="$(nvidia-smi --query-gpu=pcie.link.gen.max --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)"
if [[ "${max}" != "2" && "${max}" != "3" && "${max}" != "4" ]]; then
  echo "retrain: Device Max=${max}; skip"
  exit 0
fi

python3 - <<'PY'
import os, mmap, struct, time, subprocess

GPU, UP = "0a:00.0", "09:01.0"
PATH = "/sys/bus/pci/devices/0000:0a:00.0/resource0"

def run(cmd):
    return subprocess.check_output(cmd, text=True).strip()

def bar0_open():
    fd = os.open(PATH, os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, os.path.getsize(PATH), access=mmap.ACCESS_WRITE)
    return fd, m

def r(m, off):
    return struct.unpack_from("<I", m, off)[0]

def w(m, off, val):
    struct.pack_into("<I", m, off, val & 0xFFFFFFFF)

fd, m = bar0_open()
bar0 = r(m, 0)
cya = r(m, 0x8C2C0)
cap = r(m, 0x88084)
link = r(m, 0x8C040)
xve = r(m, 0x8872C)
misc1 = r(m, 0x8841c)
print(
    f"retrain: pre bar0={bar0:08x} CYA={cya:08x} DIS_G2={(cya>>2)&1} "
    f"MAX={(link>>18)&3} CAP={cap:08x} XVE={xve:08x} MISC1={misc1:08x}"
)
if bar0 == 0xFFFFFFFF or cya == 0xFFFFFFFF:
    print("retrain: BAR0 dead; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)
if ((cya >> 2) & 1) != 0:
    print("retrain: DIS_G2 still set; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)
if (cap & 0xF) < 2:
    print(f"retrain: Cap Gen{cap & 0xF}; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)
m.close(); os.close(fd)

for bdf in (UP, GPU):
    cur = int(run(["setpci", "-s", bdf, "CAP_EXP+30.w"]), 16)
    subprocess.check_call(["setpci", "-s", bdf, f"CAP_EXP+30.w={(cur & ~0xF) | 0x2:04x}"])
    print(f"retrain: TLS {bdf} {cur:04x} -> {run(['setpci','-s',bdf,'CAP_EXP+30.w'])}")

time.sleep(0.2)
fd, m = bar0_open()
if r(m, 0) == 0xFFFFFFFF:
    print("retrain: BAR0 dead after TLS; skip")
    m.close(); os.close(fd)
    raise SystemExit(0)

w(m, 0x8C2C0, r(m, 0x8C2C0) & ~(1 << 2))
w(m, 0x8C040, (r(m, 0x8C040) & ~0xC0000) | (2 << 18))
time.sleep(0.05)
cya = r(m, 0x8C2C0)
mx = (r(m, 0x8C040) >> 18) & 3
alive = r(m, 0) != 0xFFFFFFFF
print(f"retrain: post CYA={cya:08x} DIS_G2={(cya>>2)&1} MAX={mx} bar0={r(m,0):08x}")
m.close(); os.close(fd)

if not alive or ((cya >> 2) & 1) != 0 or mx != 2:
    print("retrain: preconditions failed; skip")
    raise SystemExit(0)

cur = int(run(["setpci", "-s", UP, "CAP_EXP+10.w"]), 16)
subprocess.check_call(["setpci", "-s", UP, f"CAP_EXP+10.w={(cur | 0x20):04x}"])
time.sleep(2.0)

sta = int(run(["setpci", "-s", GPU, "CAP_EXP+12.w"]), 16)
print(f"retrain: speed_after={sta & 0xF}")
PY
