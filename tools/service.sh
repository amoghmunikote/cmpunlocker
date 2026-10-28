#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_NAME="gen2.service"
SERVICE_SOURCE="${PROJECT_DIR}/systemd/${SERVICE_NAME}"
SERVICE_TARGET="/etc/systemd/system/${SERVICE_NAME}"
HAMMER_SOURCE="${SCRIPT_DIR}/hammer.sh"
HAMMER_TARGET="/usr/local/sbin/gen2-hammer"
LOG_FILE="/var/log/gen2.log"

source "${PROJECT_DIR}/common/lib.sh"

usage() {
    cat <<EOF
Usage:
  sudo $0 install   Install and enable the early-boot Gen2 service
  sudo $0 remove    Disable and remove the service (driver remains installed)

install never starts the retrain loop in the current session; it only arms
the service for the next boot. Check negotiated Gen2 with: ./tools.sh status verify
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this action as root"
}

supported_gpus() {
    for id in 20c2 2082; do
        lspci -D -d "10de:${id}" 2>/dev/null | awk '{print $1}'
    done
}

install_service() {
    local module
    module="/lib/modules/$(uname -r)/updates/cmpunlocker/nvidia.ko"
    local -a gpus=()

    require_root
    command -v install >/dev/null || die "install command not found"
    command -v lspci >/dev/null || die "lspci not found (install pciutils)"
    command -v setpci >/dev/null || die "setpci not found (install pciutils)"
    [[ -f "${HAMMER_SOURCE}" ]] || die "Missing ${HAMMER_SOURCE}"
    [[ -f "${SERVICE_SOURCE}" ]] || die "Missing ${SERVICE_SOURCE}"

    mapfile -t gpus < <(supported_gpus)
    [[ ${#gpus[@]} -gt 0 ]] || die "No supported CMP 170HX found (10de:20c2 / 10de:2082)"
    info "Detected: ${gpus[*]}"

    if [[ ! -f "${module}" ]]; then
        die "Patched cmpunlocker module not found: ${module}"
    fi
    if ! grep -aFq 'CMP Gen2:' "${module}" 2>/dev/null; then
        die "Installed module does not contain the Gen2 probe-retrain patch; refusing to arm a useless retrain service"
    fi
    ok "Installed NVIDIA module contains the Gen2 probe-retrain patch"

    install -m 0755 "${HAMMER_SOURCE}" "${HAMMER_TARGET}"
    install -m 0644 "${SERVICE_SOURCE}" "${SERVICE_TARGET}"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null
    ok "Enabled ${SERVICE_NAME} for the next boot"
    info "The service was not started now; the active desktop PCIe link was not touched."
    info "Recovery boot option: systemd.mask=${SERVICE_NAME}"
}

remove_service() {
    require_root
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_TARGET}" "${HAMMER_TARGET}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    ok "Removed ${SERVICE_NAME}; cmpunlocker driver and memory unlock were left intact"
    if [[ -f "${LOG_FILE}" ]]; then
        info "Preserved diagnostic log: ${LOG_FILE}"
    fi
}

case "${1:-}" in
    install) install_service ;;
    remove) remove_service ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 1 ;;
esac
