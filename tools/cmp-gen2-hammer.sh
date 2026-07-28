#!/bin/bash
# Early-retrain mechanism adapted from studebaker8/cmp170hx-gen2 (MIT).
# This implementation adds strict device/bridge guards and project integration.
set -uo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly VENDOR_ID="10de"
readonly LOG_FILE="/var/log/cmp-gen2-early.log"
readonly TARGET_GEN="${CMP_GEN2_TARGET:-2}"
readonly MAX_ITERATIONS="${CMP_GEN2_MAX_ITERATIONS:-600}"
readonly RETRAIN_INTERVAL="${CMP_GEN2_RETRAIN_INTERVAL:-0.05}"

log() {
    local line
    line="[$(date -Is)] $*"
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true
}

read_link_status() {
    setpci -s "$1" CAP_EXP+12.w 2>/dev/null || true
}

link_generation() {
    local status
    status="$(read_link_status "$1")"
    if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
        echo $((0x${status} & 0x0f))
    else
        echo "?"
    fi
}

is_supported_gpu() {
    local bdf="$1"
    local vendor device
    [[ -r "/sys/bus/pci/devices/${bdf}/vendor" ]] || return 1
    [[ -r "/sys/bus/pci/devices/${bdf}/device" ]] || return 1
    vendor="$(<"/sys/bus/pci/devices/${bdf}/vendor")"
    device="$(<"/sys/bus/pci/devices/${bdf}/device")"
    [[ "${vendor,,}" == "0x${VENDOR_ID}" ]] || return 1
    [[ "${device,,}" == "0x20c2" || "${device,,}" == "0x2082" ]]
}

upstream_bridge() {
    local bdf="$1"
    local parent
    parent="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${bdf}")")")"
    [[ "${parent}" != "${bdf}" ]] || return 1
    [[ -e "/sys/bus/pci/devices/${parent}" ]] || return 1
    echo "${parent}"
}

is_pci_bridge() {
    local bdf="$1"
    local class
    [[ -r "/sys/bus/pci/devices/${bdf}/class" ]] || return 1
    class="$(<"/sys/bus/pci/devices/${bdf}/class")"
    [[ "${class,,}" == 0x0604* ]]
}

retrain_one() {
    local gpu="$1"
    local bridge initial status generation cap2 iteration

    if ! is_supported_gpu "${gpu}"; then
        log "${gpu}: vendor/device guard failed; refusing to touch the device"
        return 1
    fi
    bridge="$(upstream_bridge "${gpu}" || true)"
    if [[ -z "${bridge}" ]] || ! is_pci_bridge "${bridge}"; then
        log "${gpu}: no valid upstream PCI bridge found; skipping"
        return 1
    fi

    initial="$(link_generation "${gpu}")"
    if [[ "${initial}" =~ ^[0-9]+$ ]] && (( initial >= TARGET_GEN )); then
        log "${gpu}: already Gen${initial}; no retrain needed"
        return 0
    fi

    log "${gpu}: start via upstream ${bridge}; initial Gen${initial}; target Gen${TARGET_GEN}"
    for ((iteration = 1; iteration <= MAX_ITERATIONS; iteration++)); do
        if ! is_supported_gpu "${gpu}"; then
            log "${gpu}: disappeared during retrain; stopping immediately"
            return 1
        fi

        # Preserve all unrelated bits. The endpoint may clamp this request to
        # Gen1 until patch 0007 briefly exposes Gen2 support during GSP boot.
        setpci -s "${bridge}" CAP_EXP+30.w=0002:000f 2>/dev/null || true
        setpci -s "${gpu}" CAP_EXP+30.w=0002:000f 2>/dev/null || true

        # PCIe retraining must be initiated by the upstream bridge.
        setpci -s "${bridge}" CAP_EXP+10.w=0020:0020 2>/dev/null || true

        status="$(read_link_status "${gpu}")"
        if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
            generation=$((0x${status} & 0x0f))
            if (( generation >= TARGET_GEN )); then
                cap2="$(setpci -s "${gpu}" CAP_EXP+2c.l 2>/dev/null || echo unreadable)"
                log "${gpu}: SUCCESS Gen${generation} at iteration ${iteration}; LnkSta=0x${status}; LnkCap2=0x${cap2}"
                return 0
            fi
        fi
        sleep "${RETRAIN_INTERVAL}"
    done

    generation="$(link_generation "${gpu}")"
    log "${gpu}: no Gen2 window caught after ${MAX_ITERATIONS} attempts; final Gen${generation}"
    return 1
}

main() {
    local rc=0
    local -a gpus=()

    if [[ "${EUID}" -ne 0 ]]; then
        echo "cmp-gen2-hammer must run as root" >&2
        exit 1
    fi
    if [[ "${TARGET_GEN}" != "2" ]]; then
        echo "Only Gen2 is supported by this safety-constrained helper" >&2
        exit 1
    fi
    if ! [[ "${MAX_ITERATIONS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "CMP_GEN2_MAX_ITERATIONS must be a positive integer" >&2
        exit 1
    fi
    command -v lspci >/dev/null || { echo "lspci is required" >&2; exit 1; }
    command -v setpci >/dev/null || { echo "setpci is required" >&2; exit 1; }

    : > "${LOG_FILE}"
    log "early retrain started (attempts=${MAX_ITERATIONS}, interval=${RETRAIN_INTERVAL}s)"

    mapfile -t gpus < <(
        for id in 20c2 2082; do
            lspci -D -d "${VENDOR_ID}:${id}" 2>/dev/null | awk '{print $1}'
        done
    )
    if [[ ${#gpus[@]} -eq 0 ]]; then
        log "no supported CMP 170HX found; nothing touched"
        return 0
    fi

    for gpu in "${gpus[@]}"; do
        retrain_one "${gpu}" || rc=1
    done
    log "early retrain finished (rc=${rc})"
    return "${rc}"
}

main "$@"
