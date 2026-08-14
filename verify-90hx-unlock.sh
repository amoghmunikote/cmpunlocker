#!/usr/bin/env bash
# Post-reboot verification for the CMP 90HX persistent compute unlock.
# Safe to re-run at any time; it only reads state and runs a benchmark.
set -uo pipefail

BUNDLE=/home/jonathan/cmpunlocker/pearlfortune-cmpunlocker/cmpunlocker-v0.1.28-linux-x64-90hx-stockflow
BIN="${BUNDLE}/cmpunlocker-rs"
LOG=/home/jonathan/cmpunlocker/verify-90hx-unlock.log

exec > >(tee "${LOG}") 2>&1

echo "=============================================="
echo " CMP 90HX unlock verification  $(date -Is)"
echo "=============================================="

echo
echo "--- 1. kernel / driver ---"
echo "kernel        : $(uname -r)"
echo "nvidia version: $(modinfo -F version nvidia 2>/dev/null)"
echo "nvidia license: $(modinfo -F license nvidia 2>/dev/null)"
echo "nvidia path   : $(modinfo -n nvidia 2>/dev/null)"

if modinfo -n nvidia 2>/dev/null | grep -q "updates/cmpunlocker-90hx-stockflow"; then
    echo "RESOLUTION    : OK - using stockflow modules"
else
    echo "RESOLUTION    : *** NOT on stockflow path - unlock will NOT be active ***"
fi

echo
echo "--- 2. GPU present ---"
nvidia-smi --query-gpu=name,vbios_version,memory.total,power.limit --format=csv 2>&1

echo
echo "--- 3. unlock state (authoritative) ---"
sudo "${BIN}" compute90hx-v67 verify --all-cmp90hx --expect full 2>&1 | grep -E "^(PASS|FAIL|error|TARGET)" || true

echo
echo "--- 4. throughput ---"
if [[ -x /home/jonathan/cmpunlocker/bench/bench2 ]]; then
    /home/jonathan/cmpunlocker/bench/bench2 2>&1
else
    echo "(bench2 not found)"
fi

echo
echo "--- 5. expected values if unlock is ACTIVE ---"
cat <<'EOF'
  verify        : PASS_CMP90HX_ALL_TARGETS_FULL_SPEED
  FP32 GEMM     : ~18 TFLOP/s      (locked baseline was 0.72)
  TF32 tensor   : ~41 TFLOP/s      (locked baseline was 1.45)
  FP16->FP32    : ~80 TFLOP/s      (locked baseline was 2.90)

If numbers are near the locked baseline, the unlock did not take effect.
To roll back to stock module resolution:
  cd /home/jonathan/cmpunlocker/pearlfortune-cmpunlocker/cmpunlocker-v0.1.28-linux-x64-90hx-stockflow/stockflow/610.43.03
  sudo ./stockflow-restore.sh --acknowledge I-ACCEPT-90HX-STOCKFLOW-RESTORE
  sudo reboot
EOF

echo
echo "Log written to ${LOG}"
