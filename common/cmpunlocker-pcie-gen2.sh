#!/bin/bash
# cmpunlocker — PCIe Gen2 link retrain for the CMP 170HX (and siblings).
#
# The card advertises PCIe Gen2 (5GT/s) in its Link Capabilities, but the link
# trains at Gen1 (2.5GT/s) until a retrain is issued from the *upstream* root
# port — setting the target speed on the endpoint alone does not drive the
# negotiation. This writes the Gen2 target on both ends and sets the Retrain
# Link bit on the root port. It lives in PCIe config space, so it resets on
# reboot / link-down and must run on every boot (installed as a systemd unit).
#
# Width is not touched: the 170HX is electrically x4, so x4 is expected.
set -uo pipefail

VENDOR="10de"
DEVICE_IDS=("20c2" "2082" "20b0")

# PCIe capability register offsets, relative to the Express capability (CAP_EXP)
LNKCTL="CAP_EXP+0x10.w"    # Link Control:  bit 5 = Retrain Link
LNKSTA="CAP_EXP+0x12.w"    # Link Status:   bits 3:0 = Current Link Speed
LNKCTL2="CAP_EXP+0x30.w"   # Link Control 2: bits 3:0 = Target Link Speed
GEN2="0x2"                 # encoded link speed for 5GT/s

log() { echo "cmpunlocker-pcie-gen2: $*"; }

command -v setpci >/dev/null 2>&1 || { log "setpci not found (install pciutils)"; exit 1; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { log "must run as root"; exit 1; }

# Current negotiated speed as a Gen number (1, 2, ...) for a device BDF.
current_gen() {
    local dev="$1" v
    v="$(setpci -s "${dev}" "${LNKSTA}" 2>/dev/null || echo "")"
    [[ -n "${v}" ]] || { echo "?"; return; }
    echo $(( 0x${v} & 0xf ))
}

retrain_one() {
    local gpu="$1" rp before after
    rp="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${gpu}")")")"
    if [[ ! -e "/sys/bus/pci/devices/${rp}" || "${rp}" == "${gpu}" ]]; then
        log "${gpu}: no upstream root port found, skipping"
        return 1
    fi

    before="$(current_gen "${gpu}")"
    if [[ "${before}" == "2" ]]; then
        log "${gpu}: already at Gen2 (root port ${rp}), nothing to do"
        return 0
    fi

    # Target Gen2 on both ends, then retrain from the root port.
    setpci -s "${rp}"  "${LNKCTL2}=${GEN2}:0xf" 2>/dev/null || true
    setpci -s "${gpu}" "${LNKCTL2}=${GEN2}:0xf" 2>/dev/null || true
    setpci -s "${rp}"  "${LNKCTL}=0x20:0x20"    2>/dev/null || true
    sleep 1

    after="$(current_gen "${gpu}")"
    if [[ "${after}" == "2" ]]; then
        log "${gpu}: retrained Gen${before} -> Gen2 (root port ${rp})"
        return 0
    fi
    log "${gpu}: retrain did not hold (Gen${before} -> Gen${after}); link may not sustain Gen2"
    return 1
}

mapfile -t GPUS < <(
    for id in "${DEVICE_IDS[@]}"; do
        lspci -D -d "${VENDOR}:${id}" 2>/dev/null | awk '{print $1}'
    done
)

if [[ ${#GPUS[@]} -eq 0 ]]; then
    log "no supported CMP card found (${VENDOR}:${DEVICE_IDS[*]})"
    exit 0
fi

rc=0
for gpu in "${GPUS[@]}"; do
    retrain_one "${gpu}" || rc=1
done
exit "${rc}"
