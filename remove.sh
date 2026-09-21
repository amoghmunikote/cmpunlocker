#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cmpunlocker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/cmpunlocker"
PASSTHROUGH_LIB="/usr/local/lib/cmpunlocker"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/driver/VERSION" 2>/dev/null || true)

source "${SCRIPT_DIR}/common/lib.sh"

banner

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
    warn "This removes cmpunlocker patched kernel modules:"
    echo "  - Stops cmpunlocker systemd service"
    echo "  - Removes /lib/modules/*/updates/cmpunlocker/"
    echo "  - Removes ${INSTALL_DIR} (legacy install dir, if present)"
    echo "  - Removes cmpretrain service / modprobe Gen2 helpers"
    echo "  - Removes VM passthrough helpers (service, udev rule, vfio modprobe conf)"
    echo "  - Rebuilds the stock nvidia DKMS modules that install.sh removed"
    echo "  - Activates stock NVIDIA modules after the next cold boot"
    echo "  - Restores the pre-install kernel command line (reverts IOMMU changes)"
    echo ""
    echo "Run: sudo ./remove.sh --yes"
    exit 1
fi

step_init 5

step "Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./remove.sh --yes"
ok "Running as root"

LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="/tmp"
fi
LOG_FILE="${LOG_DIR}/remove_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

step "Stopping cmpunlocker service and PCIe/IOMMU helpers"
info "Removing automatic rebuilds and cmpunlocker's package holds"
python3 "${SCRIPT_DIR}/persist/manage.py" uninstall
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

info "Removing PCIe Gen2 helpers"
for legacy_unit in cmpretrain.service cmp-gen2-retrain.service; do
    systemctl disable --now "${legacy_unit}" 2>/dev/null || true
    systemctl reset-failed "${legacy_unit}" 2>/dev/null || true
done
rm -f /etc/systemd/system/cmpretrain.service /usr/local/sbin/retrain.sh
rm -f /etc/systemd/system/cmp-gen2-retrain.service /usr/local/sbin/cmp-gen2-retrain.sh
rm -f /etc/modprobe.d/cmp-pcie-gen2.conf
systemctl disable --now gen2.service 2>/dev/null || true
systemctl reset-failed gen2.service 2>/dev/null || true
rm -f /etc/systemd/system/gen2.service /usr/local/sbin/gen2-hammer
ok "Removed PCIe Gen2 helpers"

info "Removing VM passthrough helpers"
systemctl disable --now cmpunlocker-passthrough.service 2>/dev/null || true
systemctl reset-failed cmpunlocker-passthrough.service 2>/dev/null || true
rm -f /etc/systemd/system/cmpunlocker-passthrough.service \
      /etc/udev/rules.d/99-cmpunlocker-passthrough.rules \
      /etc/modprobe.d/cmpunlocker-vfio.conf
rm -rf "${PASSTHROUGH_LIB}"
udevadm control --reload-rules 2>/dev/null || true
if grep -q '^cmp_no_bus_reset ' /proc/modules; then
    rmmod cmp_no_bus_reset 2>/dev/null || true
fi
mapfile -t cmp_bdfs < <(lspci -Dn 2>/dev/null | awk '/10de:20c2|10de:2082/{print $1}')
for bdf in "${cmp_bdfs[@]}"; do
    printf 'default' > "/sys/bus/pci/devices/${bdf}/reset_method" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
ok "Removed VM passthrough helpers"

info "Restoring IOMMU kernel command line"
iommu_restored=0
for cfg in /etc/default/grub /etc/kernel/cmdline; do
    if [[ -f "${cfg}.cmpunlocker.bak" ]]; then
        mv -f "${cfg}.cmpunlocker.bak" "${cfg}"
        ok "Restored ${cfg} from pre-install backup"
        iommu_restored=1
    fi
done
if (( iommu_restored )); then
    if command -v update-grub &>/dev/null; then
        update-grub 2>/dev/null || true
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
    ok "Reverted IOMMU kernel parameters (effective after reboot)"
else
    warn "No IOMMU config backup found — kernel command line left as-is"
fi

step "Removing patched modules and restoring stock NVIDIA modules"
restore_stock_modules() {
    local kernel="$1" ver
    if modprobe -n -q -S "${kernel}" nvidia 2>/dev/null; then
        ok "Stock nvidia module present for kernel ${kernel}: $(modinfo -n -k "${kernel}" nvidia 2>/dev/null || true)"
        return 0
    fi
    if ! command -v dkms &>/dev/null; then
        warn "No nvidia module for kernel ${kernel} and dkms is not installed — reinstall your distro's nvidia driver package"
        return 0
    fi
    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        [[ -f "/usr/src/nvidia-${ver}/dkms.conf" ]] || continue
        info "Rebuilding stock nvidia ${ver} DKMS modules for kernel ${kernel} (install.sh removed them)..."
        if dkms install "nvidia/${ver}" -k "${kernel}"; then
            ok "Stock nvidia ${ver} modules restored for kernel ${kernel}"
            return 0
        fi
        warn "dkms install nvidia/${ver} failed for kernel ${kernel}"
    done
    warn "No stock nvidia DKMS source found for kernel ${kernel} — reinstall your distro's nvidia driver package"
    return 0
}

mod_removed=0
kernels=("$(uname -r)")
shopt -s nullglob
for mod_dir in /lib/modules/*/updates/cmpunlocker; do
    if [[ -d "${mod_dir}" ]]; then
        kernel="$(basename "$(dirname "$(dirname "${mod_dir}")")")"
        rm -rf "${mod_dir}"
        ok "Removed patched modules for kernel ${kernel}"
        mod_removed=$((mod_removed + 1))
        [[ " ${kernels[*]} " == *" ${kernel} "* ]] || kernels+=("${kernel}")
    fi
done
[[ "${mod_removed}" -gt 0 ]] || warn "No patched kernel modules found"

for kernel in "${kernels[@]}"; do
    depmod -a "${kernel}" 2>/dev/null || true
    restore_stock_modules "${kernel}"
done
sync

info "Rebuilding initramfs so stock modules are packed again..."
for kernel in "${kernels[@]}"; do
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

step "Leaving the running NVIDIA driver loaded until cold boot"
info "Live reloads can hang CMP systems. Stock modules will load at the next boot."

step "Done"
banner
echo "cmpunlocker has been removed from system."
echo "Log saved to: ${LOG_FILE}"
echo ""
echo "Power off and power on to finish removal:"
echo -e "  ${CYAN}sudo shutdown -h now${NC}"
echo ""
