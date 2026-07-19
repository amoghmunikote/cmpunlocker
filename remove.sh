#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cmpunlocker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/cmpunlocker"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

step() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   cmpunlocker — System Removal         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
    warn "This removes cmpunlocker patched kernel modules:"
    echo "  - Stops leftover cmpunlocker systemd service (if present)"
    echo "  - Removes /lib/modules/*/updates/cmpunlocker/"
    echo "  - Removes ${INSTALL_DIR} (legacy install dir, if present)"
    echo "  - Reloads stock NVIDIA modules (brief display interruption)"
    echo ""
    echo "Run: sudo ./remove.sh --yes"
    exit 1
fi

step "Step 1/5: Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./remove.sh --yes"
ok "Running as root"

LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="/tmp"
fi
LOG_FILE="${LOG_DIR}/remove_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

step "Step 2/5: Stopping leftover cmpunlocker service"
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl stop "${SERVICE_NAME}" || true
    ok "Service stopped"
else
    warn "Service not running"
fi
if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}" || true
    ok "Service disabled"
fi
if [[ -f "${SERVICE_FILE}" ]]; then
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    ok "Removed ${SERVICE_FILE}"
fi
pkill -f "${INSTALL_DIR}/daemon/watchdog.py" 2>/dev/null || true

step "Step 3/5: Removing patched modules and legacy files"
mod_removed=0
kernels_touched=()
shopt -s nullglob
for mod_dir in /lib/modules/*/updates/cmpunlocker; do
    if [[ -d "${mod_dir}" ]]; then
        kernel="$(basename "$(dirname "$(dirname "${mod_dir}")")")"
        rm -rf "${mod_dir}"
        depmod -a "${kernel}" 2>/dev/null || true
        ok "Removed patched modules for kernel ${kernel}"
        mod_removed=$((mod_removed + 1))
        kernels_touched+=("${kernel}")
    fi
done
[[ "${mod_removed}" -gt 0 ]] || warn "No patched kernel modules found"

if [[ ${#kernels_touched[@]} -gt 0 ]]; then
    info "Rebuilding initramfs so stock modules are packed again..."
    for kernel in "${kernels_touched[@]}"; do
        if command -v update-initramfs &>/dev/null; then
            update-initramfs -u -k "${kernel}" 2>/dev/null || true
        elif command -v dracut &>/dev/null; then
            dracut --force --kver "${kernel}" 2>/dev/null || true
        fi
    done
    if command -v mkinitcpio &>/dev/null && ! command -v update-initramfs &>/dev/null && ! command -v dracut &>/dev/null; then
        mkinitcpio -P 2>/dev/null || true
    fi
    ok "initramfs rebuild attempted"
fi

for gsp in /lib/firmware/nvidia/*/gsp_tu10x.bin; do
    rm -f \
        "${gsp}.cmpunlocker.bak" \
        "${gsp}.cmpunlocker.patched" \
        "${gsp}.cmpunlocker.tmp" \
        "${gsp}.cmpunlocker.cleanup" \
        "${gsp}.cmpunlocker.pat"
done

if [[ -d "${INSTALL_DIR}" ]]; then
    rm -rf "${INSTALL_DIR}"
    ok "Removed ${INSTALL_DIR}"
else
    warn "${INSTALL_DIR} not found (ok for module-only installs)"
fi

step "Step 4/5: Reloading stock NVIDIA driver"
if lsmod | grep -q '^nvidia'; then
    warn "Unloading NVIDIA modules (display may flicker)"
    for svc in gdm3 sddm lightdm display-manager; do
        systemctl stop "${svc}" 2>/dev/null || true
    done
    systemctl stop nvidia-persistenced 2>/dev/null || true
    killall -9 Xorg Xwayland nvidia-persistenced 2>/dev/null || true
    sleep 1

    for mod in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        modprobe -r "${mod}" 2>/dev/null || true
    done
    sleep 1

    if lsmod | grep -q '^nvidia'; then
        for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            rmmod -f "${mod}" 2>/dev/null || true
        done
    fi

    if modprobe nvidia 2>/dev/null; then
        modprobe nvidia-modeset 2>/dev/null || true
        modprobe nvidia-uvm 2>/dev/null || true
        modprobe nvidia-drm 2>/dev/null || true
        ok "Stock NVIDIA driver reloaded"
    else
        warn "Could not reload NVIDIA driver — reboot to finish cleanup"
    fi

    for svc in gdm3 sddm lightdm display-manager; do
        if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            systemctl start "${svc}" 2>/dev/null || true
            break
        fi
    done
else
    warn "NVIDIA modules not loaded — skipping driver reload"
fi

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}   ${GREEN}✓ cmpunlocker removed from system${CYAN}    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Log saved to: ${LOG_FILE}"
echo ""
echo "If the GPU or display is not working, reboot once:"
echo -e "  ${CYAN}sudo reboot${NC}"
echo ""
