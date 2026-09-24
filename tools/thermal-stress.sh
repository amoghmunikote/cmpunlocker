#!/bin/bash
# Load every unlocked GPU and follow core/HBM temperature live, aborting if any
# sensor crosses a limit. Needs no root: the load is an ordinary CUDA process
# and every reading comes from nvidia-smi.
#
# The abort runs in a detached watchdog rather than in the display loop below,
# so losing the terminal (or an ssh drop) cannot leave the cards loaded and
# unguarded.
set -uo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LOG_DIR="${SCRIPT_DIR}/../logs"
# Matches the per-GPU load processes only: this script is .sh, not .py, so it
# never matches itself.
readonly LOAD_PAT='thermal-stress\.py'

DURATION=600
LIMIT=85
INTERVAL=15
SETTLE=0

for arg in "$@"; do
    case "${arg}" in
        --duration=*) DURATION="${arg#*=}" ;;
        --limit=*)    LIMIT="${arg#*=}" ;;
        --interval=*) INTERVAL="${arg#*=}" ;;
        --settle=*)   SETTLE="${arg#*=}" ;;
        -h|--help)
            cat <<'EOF'
Usage: ./tools/thermal-stress.sh [--duration=600] [--limit=85] [--interval=15]
                                 [--settle=0]

  --duration=N   Seconds to sustain load (default 600)
  --limit=N      Abort if any core OR memory sensor exceeds N degrees C
                 (default 85)
  --interval=N   Seconds between live readings (default 15). The abort is
                 checked every 3s regardless of this.
  --settle=N     Before loading, wait up to N seconds for the hottest card to
                 stop falling. Results are only comparable between runs that
                 start from the same thermal state: die temperature alone
                 settles long before the heatsinks and chassis air do, so a run
                 started too soon after a previous one heats far faster and can
                 hit the limit that a cold-start run holds under.

Writes a CSV of the full run to logs/thermal_<timestamp>.csv.
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Try: ./tools/thermal-stress.sh --help" >&2
            exit 1
            ;;
    esac
done

readonly DURATION LIMIT INTERVAL SETTLE

command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found" >&2; exit 1; }
python3 -c "import torch" 2>/dev/null || { echo "python3 with torch required" >&2; exit 1; }

GPU_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
readonly GPU_COUNT
[[ "${GPU_COUNT}" -gt 0 ]] || { echo "No GPUs visible to nvidia-smi" >&2; exit 1; }

if pgrep -f "${LOAD_PAT}" >/dev/null; then
    echo "A thermal-stress run is already in progress; refusing to start another." >&2
    exit 1
fi

# install.sh runs as root and leaves logs/ root-owned, but this tool needs no
# root -- fall back to a writable directory rather than losing the telemetry.
STAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOG_DIR}" 2>/dev/null
if [[ -w "${LOG_DIR}" ]]; then
    CSV="${LOG_DIR}/thermal_${STAMP}.csv"
else
    CSV="${TMPDIR:-/tmp}/thermal_${STAMP}.csv"
    echo "Note: ${LOG_DIR} is not writable; writing telemetry to ${CSV}"
fi
readonly STAMP CSV
RUN_DIR="$(mktemp -d)"
readonly RUN_DIR
readonly ABORT_FILE="${RUN_DIR}/abort"

WATCHDOG_PID=""
SAMPLER_PID=""

cleanup() {
    pkill -f "${LOAD_PAT}" 2>/dev/null
    [[ -n "${WATCHDOG_PID}" ]] && kill "${WATCHDOG_PID}" 2>/dev/null
    [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" 2>/dev/null
    rm -rf "${RUN_DIR}"
    return 0
}
trap cleanup EXIT INT TERM

echo "GPUs: ${GPU_COUNT}   duration: ${DURATION}s   abort above: ${LIMIT}C"
nvidia-smi --query-gpu=index,enforced.power.limit,persistence_mode \
    --format=csv,noheader | sed 's/^/  GPU /'

if [[ "${SETTLE}" -gt 0 ]]; then
    echo "Settling (up to ${SETTLE}s) so this run starts comparable to others..."
    prev=999
    for (( waited = 0; waited < SETTLE; waited += 20 )); do
        now="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits \
               2>/dev/null | sort -rn | head -1)"
        [[ -n "${now}" ]] || break
        echo "  hottest core ${now}C"
        # Stop once it stops falling: that is as cold as this chassis gets.
        [[ "${now}" -ge "${prev}" ]] && break
        prev="${now}"
        sleep 20
    done
fi

# Watchdog first, so no load ever runs unguarded.
(
    for (( i = 0; i < 90; i++ )); do
        pgrep -f "${LOAD_PAT}" >/dev/null && break
        sleep 1
    done
    while pgrep -f "${LOAD_PAT}" >/dev/null; do
        hot="$(nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory \
               --format=csv,noheader,nounits 2>/dev/null \
               | awk -F', ' -v l="${LIMIT}" \
                   '$2+0>l || $3+0>l {print "GPU" $1 " core=" $2 "C mem=" $3 "C"}')"
        if [[ -n "${hot}" ]]; then
            pkill -f "${LOAD_PAT}"
            printf '%s\n' "${hot}" > "${ABORT_FILE}"
            exit 0
        fi
        sleep 3
    done
) &
WATCHDOG_PID=$!

nvidia-smi --query-gpu=timestamp,index,temperature.gpu,temperature.memory,power.draw,enforced.power.limit,clocks.sm,clocks.mem,utilization.gpu,pstate,clocks_event_reasons.active \
    --format=csv -l 5 > "${CSV}" 2>&1 &
SAMPLER_PID=$!

for (( gpu = 0; gpu < GPU_COUNT; gpu++ )); do
    setsid python3 -u "${SCRIPT_DIR}/thermal-stress.py" "${gpu}" "${DURATION}" \
        > "${RUN_DIR}/gpu${gpu}.log" 2>&1 < /dev/null &
done

# Allocating the buffers takes a few seconds; do not call that a finished run.
for (( i = 0; i < 90; i++ )); do
    pgrep -f "${LOAD_PAT}" >/dev/null && break
    sleep 1
done
if ! pgrep -f "${LOAD_PAT}" >/dev/null; then
    echo "Load failed to start:" >&2
    tail -n 5 "${RUN_DIR}"/gpu*.log >&2
    exit 1
fi

printf '\n%6s' "t+s"
for (( gpu = 0; gpu < GPU_COUNT; gpu++ )); do
    printf '%22s' "GPU${gpu} core/mem pw clk"
done
printf '\n'

START="${SECONDS}"
while pgrep -f "${LOAD_PAT}" >/dev/null; do
    printf '%6s' "$(( SECONDS - START ))"
    while IFS=', ' read -r _ core mem watt clk; do
        printf '%12s %4sW %5sMHz' "${core}/${mem}C" "${watt%.*}" "${clk}"
    done < <(nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory,power.draw,clocks.sm \
             --format=csv,noheader,nounits 2>/dev/null)
    printf '\n'
    sleep "${INTERVAL}"
done

kill "${SAMPLER_PID}" 2>/dev/null
SAMPLER_PID=""
sleep 1

echo
if [[ -f "${ABORT_FILE}" ]]; then
    echo "ABORTED -- exceeded ${LIMIT}C:"
    sed 's/^/  /' "${ABORT_FILE}"
elif grep -qh "TFLOP" "${RUN_DIR}"/gpu*.log 2>/dev/null; then
    echo "COMPLETED ${DURATION}s at or below ${LIMIT}C"
else
    echo "ENDED EARLY without reporting -- check the load output below"
    tail -n 5 "${RUN_DIR}"/gpu*.log
fi

echo "Throughput:"
grep -h "TFLOP" "${RUN_DIR}"/gpu*.log 2>/dev/null | sort | sed 's/^/  /' \
    || echo "  (load stopped before reporting)"
echo "CSV: ${CSV}"
