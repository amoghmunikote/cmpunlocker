#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

MOD_NAME="cmp_no_bus_reset"
LIB="/usr/local/lib/cmpunlocker"
ARM="${LIB}/passthrough-arm"
GSP="${LIB}/gsp-restore"

usage() {
    cat <<'EOF'
Usage: sudo ./tools/passthrough.sh status  [<pci-address>...]
       sudo ./tools/passthrough.sh prepare <pci-address> [<pci-address>...]
       sudo ./tools/passthrough.sh restore <pci-address> [<pci-address>...]

install.sh already sets passthrough up. Cards are armed at every boot and the GSP
boot registers are restored automatically whenever anything binds a card to vfio-pci,
so assigning a GPU to a VM in Proxmox or libvirt needs no command here at all.

This tool is for the cases that are not automatic:

  status   what state each card is in, including whether its GSP registers are clean
  prepare  bind a card to vfio-pci right now, by hand, instead of letting the
           hypervisor do it at VM start
  restore  give a card back to the host driver. Needed after a VM was killed rather
           than shut down: that leaves the ACR version stamp set, the stamp is write
           protected once set, and the next VM would get no GPU. restore clears it and
           re-arms the card.

Addresses are full PCI addresses, e.g. 0000:04:00.0.
EOF
}

nvidia_loaded() { lsmod | grep -q '^nvidia '; }

require_installed() {
    [[ -x "${ARM}" && -x "${GSP}" ]] \
        || die "passthrough helpers missing from ${LIB}; run sudo ./install.sh first"
}

check_is_cmp() {
    local bdf="$1" vd
    [[ -e "/sys/bus/pci/devices/${bdf}" ]] || die "no such PCI device: ${bdf}"
    vd="$(cat "/sys/bus/pci/devices/${bdf}/vendor" 2>/dev/null):$(cat "/sys/bus/pci/devices/${bdf}/device" 2>/dev/null)"
    case "${vd}" in
        0x10de:0x20c2|0x10de:0x2082) ;;
        *) die "${bdf} is not a CMP 170HX (${vd})" ;;
    esac
}

current_driver() {
    local l
    l="$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null || true)"
    [[ -n "${l}" ]] && basename "${l}" || echo "none"
}

unlocked_mib() {
    local bdf="$1" line
    command -v nvidia-smi &>/dev/null || { echo "?"; return 0; }
    line="$(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk -F', ' -v b="${bdf}" 'tolower($1) ~ tolower(b) {print $2}')"
    [[ -n "${line}" ]] && echo "${line}" || echo "?"
}

do_status() {
    local bdf
    printf "  %-14s %-10s %-14s %s\n" "BDF" "DRIVER" "RESET_METHOD" "MEMORY"
    for bdf in "$@"; do
        printf "  %-14s %-10s %-14s %s MiB\n" "${bdf}" "$(current_driver "${bdf}")" \
            "[$(cat "/sys/bus/pci/devices/${bdf}/reset_method" 2>/dev/null || echo '?')]" \
            "$(unlocked_mib "${bdf}")"
    done
    if lsmod | grep -q "^${MOD_NAME}"; then
        ok "${MOD_NAME} loaded (bus reset blocked)"
    else
        info "${MOD_NAME} not loaded"
    fi

    for bdf in "$@"; do
        if [[ "$(current_driver "${bdf}")" == "vfio-pci" && -x "${GSP}" ]]; then
            echo ""
            echo "  ${bdf} GSP boot state:"
            "${GSP}" show "${bdf}" 2>/dev/null || true
        fi
    done
}

do_prepare() {
    local bdf
    require_installed

    step "Checking the cards are unlocked"
    for bdf in "$@"; do
        check_is_cmp "${bdf}"
        local mib; mib="$(unlocked_mib "${bdf}")"
        [[ "${mib}" != "?" ]] || die "${bdf}: nvidia-smi cannot see it; run install.sh first"
        (( mib >= 30000 )) || die "${bdf} reports ${mib} MiB — not unlocked. Run install.sh and reboot first."
        ok "${bdf}: ${mib} MiB unlocked"
    done

    #
    # Arming is what makes the handoff safe: persistence off so nothing holds the
    # device, reset_method emptied and cmp_no_bus_reset loaded so nothing can reset it.
    # It is the same helper the boot service runs, so both paths behave identically.
    #
    step "Arming the cards"
    "${ARM}" || die "arming failed"

    step "Binding to vfio-pci"
    modprobe vfio-pci disable_idle_d3=1 2>/dev/null || true
    for bdf in "$@"; do
        if [[ "$(current_driver "${bdf}")" != "vfio-pci" ]]; then
            echo "${bdf}" > "/sys/bus/pci/devices/${bdf}/driver/unbind" 2>/dev/null || true
            echo vfio-pci > "/sys/bus/pci/devices/${bdf}/driver_override"
            echo "${bdf}" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
        fi
        [[ "$(current_driver "${bdf}")" == "vfio-pci" ]] || die "${bdf}: vfio-pci bind failed"
        ok "${bdf} -> vfio-pci"
    done

    step "Restoring GSP boot-time state"
    for bdf in "$@"; do
        "${GSP}" restore "${bdf}" || warn "${bdf}: GSP state not fully clean"
    done

    step "Done"
    do_status "$@"
    echo ""
    echo "In the guest, install only a stock NVIDIA driver — nothing from cmpunlocker."
}

do_restore() {
    local bdf need_reset=0
    require_installed

    step "Restoring GSP boot-time state"
    for bdf in "$@"; do
        check_is_cmp "${bdf}"
        if ! "${GSP}" restore "${bdf}"; then
            warn "${bdf}: ACR version stamp is stuck, this card needs a reset"
            need_reset=1
        fi
    done

    #
    # A stuck stamp was left behind by a VM that was killed rather than shut down.
    # Nothing clears it except the Booter Unload the guest never ran, or a reset - so
    # allow a reset here, which the arming otherwise blocks. Safe now: the guest is
    # gone, so no GSP is running on the card.
    #
    if (( need_reset == 1 )); then
        step "Allowing a reset so the stuck stamp can be cleared"
        rmmod "${MOD_NAME}" 2>/dev/null || true
        for bdf in "$@"; do
            printf 'default' > "/sys/bus/pci/devices/${bdf}/reset_method" 2>/dev/null || true
        done
        ok "reset re-enabled"
    fi

    step "Releasing from vfio-pci"
    for bdf in "$@"; do
        echo > "/sys/bus/pci/devices/${bdf}/driver_override" 2>/dev/null || true
        echo "${bdf}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        if (( need_reset == 1 )); then
            echo 1 > "/sys/bus/pci/devices/${bdf}/reset" 2>/dev/null || true
            sleep 2
        fi
        ok "${bdf}: released"
    done

    step "Giving the cards back to the host driver so they re-unlock"
    for bdf in "$@"; do
        echo "${bdf}" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
    done
    sleep 10
    if ! nvidia_loaded; then
        modprobe nvidia 2>/dev/null || true
        sleep 8
    fi

    step "Re-arming for the next VM"
    "${ARM}" || warn "re-arming failed"

    step "Done"
    do_status "$@"
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./tools/passthrough.sh ..."
[[ $# -ge 1 ]] || { usage; exit 1; }

ACTION="$1"; shift
case "${ACTION}" in
    prepare|restore)
        [[ $# -ge 1 ]] || { usage; exit 1; }
        banner
        step_init 6
        "do_${ACTION}" "$@"
        ;;
    status)
        if [[ $# -eq 0 ]]; then
            mapfile -t set_devs < <(lspci -Dn 2>/dev/null | awk '/10de:20c2|10de:2082/{print $1}')
            [[ ${#set_devs[@]} -gt 0 ]] || die "no CMP 170HX found"
            do_status "${set_devs[@]}"
        else
            do_status "$@"
        fi
        ;;
    -h|--help) usage ;;
    *) usage; exit 1 ;;
esac
