#!/usr/bin/env bash
# Retry the Gen2 train: fresh LTSSM override + bridge retrain.
# Safe subset of the recipe - these two actions have never wedged the card.
set -uo pipefail
BDF="${CMP90_BDF:-$(lspci -Dnn | awk '/10de:220d/ {print $1; exit}')}"
UPSTREAM_PATH="$(readlink -f /sys/bus/pci/devices/${BDF}/..)"
UPSTREAM="$(basename "$UPSTREAM_PATH")"

python3 - "$BDF" <<'PY'
import os, mmap, struct, sys
fd = os.open(f"/sys/bus/pci/devices/{sys.argv[1]}/resource0", os.O_RDWR)
m = mmap.mmap(fd, 1 << 20, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
def rd(o): return struct.unpack_from("<I", m, o)[0]
def wr(o, v): struct.pack_into("<I", m, o, v)
names = [(0x8841c, "MISC1"), (0x8c2c0, "CYA0"), (0x8c040, "LINKCFG"),
         (0x8872c, "LTSSM"), (0x88084, "LINKCAP"), (0x8e110, "OVR0"),
         (0x8e12c, "VAL3"), (0x8e11c, "OVR3"), (0x880a8, "LNKCTL2_mirror")]
print("before:")
for o, n in names:
    print(f"  {n} = 0x{rd(o):08x}")
wr(0x8872c, 0x00000006)
print(f"  LTSSM rewrite -> 0x{rd(0x8872c):08x}")
os.close(fd)
PY

sudo setpci -s "${BDF}"      CAP_EXP+2c.w=0x0002
sudo setpci -s "${UPSTREAM}" CAP_EXP+2c.w=0x0002
lnkctl="$(sudo setpci -s "${UPSTREAM}" CAP_EXP+10.w)"
printf -v newctl '0x%x' $(( (16#$lnkctl) | 0x20 ))
sudo setpci -s "${UPSTREAM}" CAP_EXP+10.w="$newctl"

for i in $(seq 1 15); do
    speed="$(cat /sys/bus/pci/devices/${BDF}/current_link_speed 2>/dev/null)"
    [[ "$speed" == "5.0 GT/s PCIe" ]] && break
    sleep 1
done
echo "link speed: ${speed:-unknown} (attempt $i)"
sudo lspci -vv -s "$BDF" 2>/dev/null | grep -E "LnkCap:|LnkSta:"
