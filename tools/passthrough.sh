#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

KVER="$(uname -r)"
MOD_SRC="${SCRIPT_DIR}/../driver/passthrough"
MOD_KO="${MOD_SRC}/cmp_no_bus_reset.ko"
MOD_NAME="cmp_no_bus_reset"

usage() {
    cat <<'EOF'
Usage: sudo ./tools/passthrough.sh prepare <pci-address> [<pci-address>...]
       sudo ./tools/passthrough.sh restore <pci-address> [<pci-address>...]
       sudo ./tools/passthrough.sh status  [<pci-address>...]

Hands an already-unlocked CMP 170HX to vfio-pci without letting anything reset it, so
the unlock the host applied is still there when a guest uses the card. The guest needs
nothing but a stock NVIDIA driver.

  prepare  unlock check -> block every reset path -> release the card -> bind vfio-pci
           -> restore the GSP boot-time registers so a guest can still boot GSP
  restore  give the card back to the host nvidia driver and re-unlock it
  status   show what state each card is in

Addresses are full PCI addresses, e.g. 0000:04:00.0.

Run this AFTER install.sh, on a host where the cards are already unlocked. Every GPU
that stays on the host is briefly taken offline, because releasing one card requires
unloading the whole nvidia stack; a per-device unbind wedges the GPU.

Shut guests down cleanly. On a clean shutdown the guest driver tears down its own GSP
state and the card is immediately ready for the next VM, with nothing to do on the
host. A killed or hard-reset VM leaves that state behind and the card then needs
`restore` followed by `prepare` again — `status` will show it.
EOF
}

nvidia_loaded() { lsmod | grep -q '^nvidia '; }

stop_nvidia() {
    systemctl stop nvidia-persistenced 2>/dev/null || true
    sleep 1
    rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
    if nvidia_loaded; then
        err "nvidia is still loaded; something is holding it:"
        lsof /dev/nvidia* 2>/dev/null | awk 'NR<6'
        die "close those and retry"
    fi
}

start_nvidia() {
    modprobe nvidia 2>/dev/null || true
    sleep 8
    systemctl start nvidia-persistenced 2>/dev/null || true
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

build_module() {
    [[ -f "${MOD_KO}" ]] && return 0
    [[ -d "/lib/modules/${KVER}/build" ]] || die "kernel headers missing for ${KVER}"
    info "Building ${MOD_NAME}.ko"
    make -C "${MOD_SRC}" >/dev/null || die "failed to build ${MOD_NAME}.ko"
    ok "Built ${MOD_KO}"
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
        if [[ "$(current_driver "${bdf}")" == "vfio-pci" ]]; then
            echo ""
            echo "  ${bdf} GSP boot state:"
            python3 "${SCRIPT_DIR}/pt-regs.py" show "${bdf}" 2>/dev/null || true
        fi
    done
}

do_prepare() {
    local bdf devs_arg=""

    step "Checking the cards are unlocked"
    for bdf in "$@"; do
        check_is_cmp "${bdf}"
        local mib; mib="$(unlocked_mib "${bdf}")"
        [[ "${mib}" != "?" ]] || die "${bdf}: nvidia-smi cannot see it; run install.sh first"
        (( mib >= 30000 )) || die "${bdf} reports ${mib} MiB — not unlocked. Run install.sh and reboot first."
        ok "${bdf}: ${mib} MiB unlocked"
    done

    build_module

    step "Blocking every reset path"
    for bdf in "$@"; do
        printf ' ' > "/sys/bus/pci/devices/${bdf}/reset_method"
        [[ -z "$(cat "/sys/bus/pci/devices/${bdf}/reset_method")" ]] \
            || die "${bdf}: could not clear reset_method"
        ok "${bdf}: reset_method cleared (FLR and bus reset refused)"
        devs_arg+=" devs=${bdf}"
    done

    step "Releasing the cards from the host driver"
    warn "every GPU on this host goes offline for a few seconds"
    stop_nvidia
    ok "nvidia stack unloaded"

    step "Binding to vfio-pci"
    modprobe vfio-pci disable_idle_d3=1
    for bdf in "$@"; do
        echo vfio-pci > "/sys/bus/pci/devices/${bdf}/driver_override"
        echo "${bdf}" > /sys/bus/pci/drivers/vfio-pci/bind
        [[ "$(current_driver "${bdf}")" == "vfio-pci" ]] || die "${bdf}: vfio-pci bind failed"
        ok "${bdf} -> vfio-pci"
    done

    rmmod "${MOD_NAME}" 2>/dev/null || true
    # shellcheck disable=SC2086
    insmod "${MOD_KO}" ${devs_arg} || die "failed to load ${MOD_NAME}.ko"
    ok "Bus reset blocked on $# card(s)"

    step "Restoring GSP boot-time state"
    for bdf in "$@"; do
        python3 "${SCRIPT_DIR}/pt-regs.py" restore "${bdf}" \
            || die "${bdf}: could not restore GSP boot state"
    done

    step "Bringing the remaining GPUs back"
    start_nvidia

    step "Done"
    do_status "$@"
    echo ""
    echo "These cards are ready to pass through. In the guest, install only a stock"
    echo "NVIDIA driver of the same version — nothing from cmpunlocker."
    echo "To hand them back to the host: sudo ./tools/passthrough.sh restore $*"
}

do_restore() {
    local bdf

    #
    # Give the card back the same way it was taken: without ever resetting it. An FLR
    # on a card whose GSP has been running leaves it unable to boot GSP again, and
    # recovering that needs a cold power cycle. So restore the GSP boot-time registers
    # first, then let the host driver boot GSP on the still-unlocked card.
    #
    step "Restoring GSP boot-time state (still no reset)"
    for bdf in "$@"; do
        check_is_cmp "${bdf}"
        python3 "${SCRIPT_DIR}/pt-regs.py" restore "${bdf}"             || warn "${bdf}: could not restore GSP boot state"
    done

    step "Releasing from vfio-pci"
    for bdf in "$@"; do
        echo > "/sys/bus/pci/devices/${bdf}/driver_override" 2>/dev/null || true
        echo "${bdf}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        ok "${bdf}: released"
    done

    step "Reloading the host driver so the cards re-unlock"
    stop_nvidia
    start_nvidia

    step "Re-enabling reset now that the host owns the cards again"
    rmmod "${MOD_NAME}" 2>/dev/null || true
    for bdf in "$@"; do
        printf 'default' > "/sys/bus/pci/devices/${bdf}/reset_method" 2>/dev/null || true
    done
    ok "reset_method back to default"

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
        step_init 7
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
