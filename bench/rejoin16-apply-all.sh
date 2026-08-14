#!/usr/bin/env bash
# CMP 90HX PCIe Gen2 unlock v2 - full apply. SUPERVISED USE ONLY.
#
# v2 architecture (stable-timing): the Gen2 speed-path registers are written
# by the rejoin16 kernel module itself, right after the stock Booter Load and
# before GSP-RM starts managing the link (same point the GA100 cmpunlocker
# uses on the 170HX). Userspace only opens the privilege masks (one crafted
# write per module reload) and performs the final bridge retrain, both of
# which have never wedged the card.
#
# Phase 1: one crafted-Booter write per module reload, opening the XVE /
#          XP3G / OPTB / FEAT_ECC privilege masks. On the last reload's boot
#          the module itself applies the Gen2 speed-path config.
# Phase 2: (none in v2 - kernel does the speed-path writes)
# Phase 3: set target link speed on both ends + bridge RL-bit retrain.
#
# HOST-CRASH WARNING: on jonathan-backup the GPU shares a PCIe switch with
# the NIC and BOTH SATA controllers (root disk included). If the GPU wedges
# its PCIe endpoint the whole machine may die. Only run this with someone
# able to hard power-cycle the box.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDF="${CMP90_BDF:-$(lspci -Dnn | awk '/10de:220d/ {print $1; exit}')}"
CYCLE="${SCRIPT_DIR}/rejoin16-cycle.sh"
SPEC=/var/lib/cmpunlocker-rs/rejoin16-next-write.bin
LOG=logger
say() { echo "rejoin16-apply-all: $*"; $LOG -t rejoin16-apply-all -- "$*" 2>/dev/null || true; }

# --- phase 1: privilege-mask opens, one module reload each ----------------
PAYLOAD_WRITES="
0x00088fe8 0xffffffff
0x00088fec 0xffffffff
0x00088ff0 0xffffffff
0x00088ff4 0xffffffff
0x00088ff8 0xffffffff
0x00088ab4 0xffffffff
0x0008e1b0 0xffffffff
0x0008e1b4 0xffffffff
0x0008e1b8 0xffffffff
0x0008e1bc 0xffffffff
0x0008e1c0 0xffffffff
0x0008e1c4 0xffffffff
0x0008e1c8 0xffffffff
0x0008e1cc 0xffffffff
0x0008e1d0 0xffffffff
0x0008e1d4 0xffffffff
0x0008e1d8 0xffffffff
0x0008e1dc 0xffffffff
0x0008e1e0 0xffffffff
0x0008e1e4 0xffffffff
0x0008e1e8 0xffffffff
0x0008e1ec 0xffffffff
0x0008e1f0 0xffffffff
0x008200d0 0xffffffff
0x008200d4 0xffffffff
0x008200d8 0xffffffff
0x008200dc 0xffffffff
0x008200e0 0xffffffff
0x008200e4 0xffffffff
0x008200e8 0xffffffff
0x008200ec 0xffffffff
0x008200f0 0xffffffff
0x008200f4 0xffffffff
0x00823800 0xffffffff
"

# --- fast path: warm reboots preserve the PLM state -------------------------
# If the masks are already open (and the speed config persisted), skip all
# 34 reload cycles and go straight to verification.
plms_open=0
if [[ "${SKIP_PHASE1:-0}" != "1" ]]; then
    plms_open="$(sudo python3 - "$BDF" <<'PY'
import os, mmap, struct, sys
fd = os.open(f"/sys/bus/pci/devices/{sys.argv[1]}/resource0", os.O_RDONLY)
m = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
# NOTE: OPTB masks re-lock on warm reboot while XVE/XP3G/FEAT persist -
# and Gen2 provably works with OPTB locked, so they are not in this set.
ok = all(struct.unpack_from("<I", m, o)[0] == 0xffffffff
         for o in (0x88ff4, 0x8e1b0, 0x823800))
os.close(fd)
print(1 if ok else 0)
PY
)"
fi

if [[ "${SKIP_PHASE1:-0}" != "1" && "$plms_open" == "1" ]]; then
    say "phase1: all masks already open (warm boot) - skipping 34 cycles"
elif [[ "${SKIP_PHASE1:-0}" != "1" ]]; then
    while read -r addr value; do
        [[ -z "$addr" ]] && continue
        cycle_out="$("$CYCLE" "$addr" "$value" 2>&1)"
        result="$(echo "$cycle_out" | grep -oE "readback=0x[0-9a-f]+ polls=[0-9]+ (OK|NO-EFFECT)" | head -1)"
        say "phase1 [$addr=$value] ${result:-NO-RESULT}"
        if [[ -z "$result" ]]; then
            say "phase1 ABORT: cycle for $addr produced no result:"
            echo "$cycle_out" | tail -5
            exit 1
        fi
        if [[ "$result" == *NO-EFFECT* ]]; then
            say "phase1 ABORT: write to $addr did not land"
            exit 1
        fi
    done <<< "$PAYLOAD_WRITES"
else
    say "phase1 skipped (SKIP_PHASE1=1)"
fi
rm -f "$SPEC"

# fast path: if the link is already at Gen2, nothing else to do
if [[ "$plms_open" == "1" ]]; then
    cur="$(cat /sys/bus/pci/devices/${BDF}/current_link_speed 2>/dev/null)"
    if [[ "$cur" == "5.0 GT/s PCIe" ]]; then
        say "link already at Gen2 (warm boot) - done in seconds, no cycles needed"
        exit 0
    fi
fi

# --- phase 2: confirm the module applied the late Gen2 config -------------
if sudo dmesg | grep -q "REJOIN16: late Gen2 config applied"; then
    sudo dmesg | grep "REJOIN16: late Gen2 config applied" | tail -1 | while read -r l; do say "  $l"; done
else
    say "phase2 WARN: no late Gen2 config line in dmesg; speed path may be unconfigured"
fi

# --- phase 3: target speed + bridge RL-bit retrain -------------------------
UPSTREAM_PATH="$(readlink -f /sys/bus/pci/devices/${BDF}/..)"
UPSTREAM="$(basename "$UPSTREAM_PATH")"
say "phase3 upstream bridge = ${UPSTREAM}"

cur_speed="$(cat /sys/bus/pci/devices/${BDF}/current_link_speed 2>/dev/null)"
[[ "$cur_speed" == "2.5 GT/s PCIe" || "$cur_speed" == "5.0 GT/s PCIe" ]] || {
    say "phase3 ABORT: link not in a known-good state ($cur_speed)"; exit 1; }

sudo setpci -s "${BDF}"      CAP_EXP+2c.w=0x0002   # target 5 GT/s (GPU)
sudo setpci -s "${UPSTREAM}" CAP_EXP+2c.w=0x0002   # target 5 GT/s (bridge)

lnkctl="$(sudo setpci -s "${UPSTREAM}" CAP_EXP+10.w)"
printf -v newctl '0x%x' $(( (16#$lnkctl) | 0x20 ))
sudo setpci -s "${UPSTREAM}" CAP_EXP+10.w="$newctl"  # retrain (RL bit only; never Link Disable)

speed=""
for i in $(seq 1 30); do
    speed="$(cat /sys/bus/pci/devices/${BDF}/current_link_speed 2>/dev/null)"
    [[ "$speed" == "5.0 GT/s PCIe" ]] && break
    sleep 1
done
say "phase3 link speed after retrain: ${speed:-unknown} (attempt $i)"

lspci -vv -s "$BDF" 2>/dev/null | grep -E "LnkCap|LnkSta" | while read -r l; do say "  $l"; done
say "done"
