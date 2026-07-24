#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/driver/VERSION")
SUPPORTED_VERSIONS_CSV="$(IFS=', '; echo "${SUPPORTED_VERSIONS[*]}")"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

PROFILE_OVERRIDE=""
for arg in "$@"; do
    case "${arg}" in
        --profile=8gb|--profile=8GB) PROFILE_OVERRIDE="8gb" ;;
        --profile=10gb|--profile=10GB) PROFILE_OVERRIDE="10gb" ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./install.sh [--profile=8gb|10gb]

  --profile=8gb   Force 8GB physical card → 64GB unlock geometry
  --profile=10gb  Force 10GB physical card → 40GB unlock geometry

Without --profile, stock nvidia-smi memory.total selects the profile:
  ~8192 MiB  → 8gb / 64GB unlock
  ~10240 MiB → 10gb / 40GB unlock
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Try: sudo ./install.sh --help" >&2
            exit 1
            ;;
    esac
done

exec > >(tee -a "${LOG_FILE}") 2>&1

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

detect_card_profile() {
    local mem_mib=""
    if command -v nvidia-smi &>/dev/null; then
        mem_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
    fi
    if [[ -z "${mem_mib}" || ! "${mem_mib}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if (( mem_mib >= 60000 )); then
        echo "8gb"
        return 0
    fi
    if (( mem_mib >= 35000 && mem_mib < 60000 )); then
        echo "10gb"
        return 0
    fi
    if (( mem_mib >= 7680 && mem_mib <= 8704 )); then
        echo "8gb"
        return 0
    fi
    if (( mem_mib >= 9728 && mem_mib <= 10752 )); then
        echo "10gb"
        return 0
    fi
    echo "unknown:${mem_mib}" >&2
    return 1
}

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║               cmpunlocker              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

step "Step 1/6: Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./install.sh"
ok "Running as root"

step "Step 2/6: Detecting CMP 170HX GPU"
PCI_LINE="$(lspci -nn 2>/dev/null | grep -iE '10de:20b0|10de:20c2|10de:2082' | head -1 || true)"
[[ -n "${PCI_LINE}" ]] || die "No CMP 170HX GPU found (10de:20b0 / 10de:20c2 / 10de:2082)"
PCI="$(echo "${PCI_LINE}" | awk '{print $1}')"
PCI_FULL="0000:${PCI}"
DEVID="$(echo "${PCI_LINE}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
ok "GPU detected: ${PCI_FULL} (10de:${DEVID})"
if [[ "${DEVID}" != "20c2" && "${DEVID}" != "2082" ]]; then
    warn "In-driver unlock path is gated on PCI ID 0x20C2 / 0x2082."
    warn "This card reports 0x${DEVID}; install will continue, but unlock may not activate."
fi

step "Step 3/6: Selecting card memory profile"
CARD_PROFILE=""
EXPECTED_MIB=""
if [[ -n "${PROFILE_OVERRIDE}" ]]; then
    CARD_PROFILE="${PROFILE_OVERRIDE}"
    ok "Profile forced via --profile=${CARD_PROFILE}"
else
    if detected_profile="$(detect_card_profile)"; then
        CARD_PROFILE="${detected_profile}"
        mem_now="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '[:space:]' || echo '?')"
        ok "Detected stock/reported memory ${mem_now} MiB → profile ${CARD_PROFILE}"
    else
        die "Could not detect 8GB vs 10GB card. Re-run with --profile=8gb or --profile=10gb"
    fi
fi

case "${CARD_PROFILE}" in
    8gb)
        EXPECTED_MIB=65536
        info "Unlock geometry: 64GB (CFG1=0x02779000 LMR=0x0000020B)"
        ;;
    10gb)
        EXPECTED_MIB=40960
        info "Unlock geometry: 40GB (CFG1=0x02669000 LMR=0x0000028A)"
        ;;
    *)
        die "Internal error: bad profile ${CARD_PROFILE}"
        ;;
esac
export CMPUNLOCKER_CARD_PROFILE="${CARD_PROFILE}"

step "Step 4/6: Verifying nvidia-open (${SUPPORTED_VERSIONS_CSV})"
[[ ${#SUPPORTED_VERSIONS[@]} -gt 0 ]] || die "No supported versions listed in driver/VERSION"
if [[ -d /sys/firmware/efi ]] && command -v mokutil &>/dev/null; then
    if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
        die "Secure Boot is enabled. Disable it before installing unsigned patched modules."
    fi
fi

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

detected=""
if [[ -r /proc/driver/nvidia/version ]]; then
    detected="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1 || true)"
fi
if [[ -z "${detected}" ]] && command -v nvidia-smi &>/dev/null; then
    detected="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
fi
if [[ -z "${detected}" ]]; then
    for cand in "${SUPPORTED_VERSIONS[@]}"; do
        if [[ -d "/lib/firmware/nvidia/${cand}" ]]; then
            detected="${cand}"
            break
        fi
    done
    if [[ -z "${detected}" ]]; then
        fw="$(ls -d /lib/firmware/nvidia/*/ 2>/dev/null | sed 's|.*/nvidia/||;s|/||' | sort -rV | head -1 || true)"
        detected="${fw}"
    fi
fi

[[ -n "${detected}" ]] || die "Could not detect an installed NVIDIA driver. Install nvidia-open ${SUPPORTED_VERSIONS_CSV} first."
version_supported "${detected}" || die "Installed driver is ${detected}, but cmpunlocker requires one of: ${SUPPORTED_VERSIONS_CSV}."
ok "NVIDIA driver ${detected} is supported"

[[ -d "/lib/modules/$(uname -r)/build" ]] || die "Kernel headers missing for $(uname -r). Install linux-headers-$(uname -r) or kernel-devel."
ok "Kernel headers present for $(uname -r)"

step "Step 5/7: Building and installing patched modules"
chmod +x "${SCRIPT_DIR}/driver/build.sh"
CMPUNLOCKER_DRIVER_VERSION="${detected}" CMPUNLOCKER_CARD_PROFILE="${CARD_PROFILE}" "${SCRIPT_DIR}/driver/build.sh"
ok "Patched modules installed (profile ${CARD_PROFILE})"

step "Step 6/7: Installing PCIe Gen2 retrain service"
# The 170HX advertises PCIe Gen2 but trains at Gen1 until the link is retrained
# from the upstream root port. That lives in PCIe config space and resets every
# boot, so install a systemd oneshot to reapply it. Independent of the in-driver
# unlock; it only touches link speed.
PCIE_SRC="${SCRIPT_DIR}/common/cmpunlocker-pcie-gen2.sh"
PCIE_BIN="/usr/local/sbin/cmpunlocker-pcie-gen2"
PCIE_SERVICE="/etc/systemd/system/cmpunlocker-pcie-gen2.service"
PCIE_RULES_SRC="${SCRIPT_DIR}/common/99-cmpunlocker-pcie-gen2.rules"
PCIE_RULES="/etc/udev/rules.d/99-cmpunlocker-pcie-gen2.rules"
if ! command -v setpci &>/dev/null; then
    warn "setpci not found (pciutils) — skipping PCIe Gen2 service; link stays at Gen1"
elif [[ ! -r "${PCIE_SRC}" ]]; then
    warn "Missing ${PCIE_SRC} — skipping PCIe Gen2 service"
else
    install -m 0755 "${PCIE_SRC}" "${PCIE_BIN}"
    ok "Installed ${PCIE_BIN}"
    cat > "${PCIE_SERVICE}" <<EOF
[Unit]
Description=cmpunlocker PCIe Gen2 link retrain for CMP 170HX
Documentation=https://github.com/eejohnso/cmpunlocker
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PCIE_BIN}

[Install]
WantedBy=multi-user.target
EOF
    ok "Wrote ${PCIE_SERVICE}"
    systemctl daemon-reload
    systemctl enable cmpunlocker-pcie-gen2.service >/dev/null 2>&1 || true
    if systemctl start cmpunlocker-pcie-gen2.service; then
        ok "PCIe Gen2 retrain applied now and enabled at boot"
    else
        warn "PCIe Gen2 service enabled for boot, but immediate run failed — check: journalctl -u cmpunlocker-pcie-gen2"
    fi
    # udev rule re-applies the retrain when the driver rebinds (reload / reset),
    # which does not produce a PCI remove/add event the boot unit would catch.
    if [[ -r "${PCIE_RULES_SRC}" ]]; then
        install -m 0644 "${PCIE_RULES_SRC}" "${PCIE_RULES}"
        udevadm control --reload-rules 2>/dev/null || true
        ok "Installed udev rule ${PCIE_RULES}"
    else
        warn "Missing ${PCIE_RULES_SRC} — driver-rebind retrain not installed"
    fi
fi

step "Step 7/7: Done"
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}   ${GREEN}✓ cmpunlocker install finished${CYAN}       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Profile: ${CARD_PROFILE} → expect ~${EXPECTED_MIB} MiB after unlock"
echo "Next:"
echo -e "  1. Cold reboot recommended: ${CYAN}sudo shutdown -h now${NC}  (then power on)"
echo -e "  2. Verify memory: ${CYAN}nvidia-smi${NC}  (expect ~${EXPECTED_MIB} MiB)"
echo -e "  3. Verify unlock logs: ${CYAN}sudo dmesg | grep SEC2_DEBUG${NC}"
echo -e "  4. Verify SM clocks: ${CYAN}nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader${NC}"
echo -e "  5. Verify PCIe Gen2: ${CYAN}nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader${NC}  (expect 2)"
echo ""
echo "Log saved to: ${LOG_FILE}"
echo ""
