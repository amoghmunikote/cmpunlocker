#!/bin/bash
set -u

MOD=cmp_no_bus_reset

log() { echo "cmpunlocker-passthrough: $*"; }

mapfile -t BDFS < <(lspci -Dn 2>/dev/null | awk '/10de:20c2|10de:2082/{print $1}')
if [[ ${#BDFS[@]} -eq 0 ]]; then
    log "no CMP 170HX present, nothing to arm"
    exit 0
fi

if command -v nvidia-smi &>/dev/null; then
    while IFS=', ' read -r idx bus; do
        [[ -n "${idx:-}" ]] || continue
        for bdf in "${BDFS[@]}"; do
            if [[ "${bus,,}" == *"${bdf,,}"* ]]; then
                nvidia-smi -i "${idx}" -pm 0 &>/dev/null \
                    && log "${bdf}: persistence mode off"
            fi
        done
    done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null)
fi

for bdf in "${BDFS[@]}"; do
    rm_file="/sys/bus/pci/devices/${bdf}/reset_method"
    [[ -w "${rm_file}" ]] || continue
    printf ' ' > "${rm_file}" 2>/dev/null || continue
    if [[ -z "$(cat "${rm_file}")" ]]; then
        log "${bdf}: reset_method cleared"
    else
        log "${bdf}: WARNING could not clear reset_method"
    fi
done

if lsmod | grep -q "^${MOD}"; then
    rmmod "${MOD}" 2>/dev/null || true
fi
devs="$(IFS=,; echo "${BDFS[*]}")"
if modprobe "${MOD}" devs="${devs}" 2>/dev/null; then
    log "bus reset blocked on ${#BDFS[@]} card(s): ${devs}"
else
    log "WARNING could not load ${MOD}; a VM would reset the card and lose the unlock"
    exit 1
fi
