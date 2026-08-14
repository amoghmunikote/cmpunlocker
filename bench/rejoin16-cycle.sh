#!/usr/bin/env bash
# Drive one rejoin16 crafted-Booter write per module reload.
#
# The GA102 V67 chain fires only once per FLR-separated boot cycle, so each
# register write needs its own unload/relock/load cycle. The rejoin16 module
# reads /var/lib/cmpunlocker-rs/rejoin16-next-write.bin (8 bytes LE:
# addr, value) in the canary-success branch and fires exactly one write.
#
# Usage: sudo ./rejoin16-cycle.sh <addr> <value>
#   e.g. sudo ./rejoin16-cycle.sh 0x00088ff4 0xffffffff
set -uo pipefail

ADDR="$1"
VALUE="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Card BDF: auto-detect the CMP 90HX (10de:220d); override with CMP90_BDF.
BDF="${CMP90_BDF:-$(lspci -Dnn | awk '/10de:220d/ {print $1; exit}')}"
# Built rejoin16 artifact dir (contains nvidia.ko etc.): set CMP90_ARTIFACT,
# or it defaults to the in-tree pearlfortune bundle build for this kernel.
ART="${CMP90_ARTIFACT:-${SCRIPT_DIR}/../pearlfortune-cmpunlocker/cmpunlocker-v0.1.28-linux-x64-90hx-stockflow/stockflow/610.43.03/artifacts/610.43.03-$(uname -r)-rejoin16-pcie-jtag-plm}"
SPEC=/var/lib/cmpunlocker-rs/rejoin16-next-write.bin
POKE="${CMP90_POKE:-${SCRIPT_DIR}/bar0poke}"
[[ -n "$BDF" ]] || { echo "FATAL: no CMP 90HX (10de:220d) found; set CMP90_BDF"; exit 2; }
[[ -f "$ART/nvidia.ko" ]] || { echo "FATAL: no nvidia.ko in $ART; set CMP90_ARTIFACT"; exit 2; }

[[ -n "$ADDR" && -n "$VALUE" ]] || { echo "usage: $0 <addr> <value>"; exit 2; }

mkdir -p /var/lib/cmpunlocker-rs
python3 - "$ADDR" "$VALUE" "$SPEC" <<'PY'
import struct, sys
addr, val, path = int(sys.argv[1], 0), int(sys.argv[2], 0), sys.argv[3]
with open(path, "wb") as f:
    f.write(struct.pack("<II", addr, val))
PY
echo "spec: $ADDR = $VALUE"

# Unload the full stack (nvidia_drm/nvidia_modeset get auto-loaded by udev
# on this system and hold nvidia busy). Retry once: things occasionally
# grab the GPU right after the previous cycle.
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia 2>/dev/null || {
    sleep 2
    modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia 2>/dev/null
} || { echo "FATAL: cannot unload nvidia stack"; exit 1; }

# Re-lock the compute selectors so the canary path runs on next load.
# (CPU-writable while FEAT_OVR_PLM is open.)
"$POKE" "$BDF" wr 0x0082381c 0x0 >/dev/null
"$POKE" "$BDF" wr 0x00823820 0x0 >/dev/null

dmesg -C 2>/dev/null || true
# nvidia.ko needs DRM symbols; removing the stack above also removed drm
modprobe drm 2>/dev/null || true
modprobe drm_kms_helper 2>/dev/null || true
insmod "$ART/nvidia.ko" || { echo "FATAL: insmod nvidia.ko failed"; exit 1; }
sleep 1
nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1   # trigger RM init
sleep 1
insmod "$ART/nvidia-uvm.ko" 2>/dev/null || true

echo "--- REJOIN16 result ---"
dmesg | grep -E "REJOIN16: (spec|fwsec|write|refill)" || echo "(no REJOIN16 lines!)"
echo "--- readback ---"
"$POKE" "$BDF" wr "$ADDR" "$VALUE" 2>/dev/null | sed 's/^/  (cpu-write probe) /' || true
