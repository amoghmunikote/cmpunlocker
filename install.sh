#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/driver/VERSION")
SUPPORTED_VERSIONS_CSV="$(IFS=', '; echo "${SUPPORTED_VERSIONS[*]}")"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

PROFILE_OVERRIDE=""
CONFIGURE_IOMMU=1
CONFIGURE_GEN2_SERVICE=1
CONFIGURE_PASSTHROUGH=1
P2P_MODE=off
DISABLE_GEN2=0
PERSIST_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        --profile=8gb|--profile=8GB) PROFILE_OVERRIDE="8gb" ;;
        --profile=10gb|--profile=10GB) PROFILE_OVERRIDE="10gb" ;;
        --no-iommu) CONFIGURE_IOMMU=0 ;;
        --no-gen2-service) CONFIGURE_GEN2_SERVICE=0 ;;
        --no-gen2) DISABLE_GEN2=1; CONFIGURE_GEN2_SERVICE=0 ;;
        --no-passthrough) CONFIGURE_PASSTHROUGH=0 ;;
        --p2p|--p2p=bar1) P2P_MODE=bar1 ;;
        --p2p=mailbox) P2P_MODE=mailbox ;;
        --p2p=off) P2P_MODE=off ;;
        --no-persist|--no-pin) PERSIST_ARGS+=("${arg}") ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./install.sh [--profile=8gb|10gb] [--no-iommu] [--no-gen2-service]
                        [--no-passthrough] [--p2p=bar1|mailbox|off] [--no-gen2]
                        [--no-persist] [--no-pin]

  --profile=8gb   Force 8GB metadata label (geometry is still chosen per PCI ID)
  --profile=10gb  Force 10GB metadata label (geometry is still chosen per PCI ID)
  --p2p[=bar1]   Enable experimental BAR1 P2P and static BAR1 mappings.
                  Requires a full BAR1 on each GPU and a working PCIe peer route.
                  Verify actual peer reads/writes after a cold boot; see docs/P2P.md.
  --p2p=mailbox  Experimental mailbox P2P; full-size BAR1 is not required.
  --p2p=off      Memory unlock only (default).
  --no-gen2      Disable both driver retrain patches, forced speed options and
                  the boot retrain service. Keep firmware link speed.
  --no-persist   Disable automatic driver rebuilds after kernel/header updates.
  --no-pin       Release only cmpunlocker's apt holds; allow NVIDIA updates.
  --no-iommu      Do not touch the kernel command line (leave IOMMU settings alone)
  --no-gen2-service
                  Do not install the early-boot PCIe Gen2 retrain service
  --no-passthrough
                  Do not set the cards up for VM passthrough. By default the
                  unlock is made to survive being handed to vfio-pci, so a VM
                  sees an unlocked card with only a stock NVIDIA driver in it

By default the installer appends intel_iommu=on / amd_iommu=on plus iommu=pt to
the kernel command line so the IOMMU runs in passthrough mode. This takes effect
on the next reboot.

Without --profile, each unlockable GPU is classified by PCI device ID:
  10de:20c2 → 8gb / 64GB unlock
  10de:2082 → 10gb / 40GB unlock

Multi-GPU and mixed 8GB+10GB systems are supported in one install.
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

source "${SCRIPT_DIR}/common/lib.sh"

banner
step_init 8

step "Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./install.sh"
ok "Running as root"

step "Detecting CMP 170HX GPU(s)"
mapfile -t PCI_LINES < <(lspci -nn 2>/dev/null | grep -iE '10de:20b0|10de:20c2|10de:2082' || true)
[[ ${#PCI_LINES[@]} -gt 0 ]] || die "No CMP 170HX GPU found (10de:20b0 / 10de:20c2 / 10de:2082)"

SMI_MEM_CACHE=""
if command -v nvidia-smi &>/dev/null; then
    SMI_MEM_CACHE="$(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
fi

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()
GPU_CURRENT=()
COUNT_8GB=0
COUNT_10GB=0
COUNT_UNSUPPORTED=0

for PCI_LINE in "${PCI_LINES[@]}"; do
    PCI="$(echo "${PCI_LINE}" | awk '{print $1}')"
    PCI_FULL="$(normalize_bus_id "${PCI}")"
    DEVID="$(echo "${PCI_LINE}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
    PROF="$(profile_from_devid "${DEVID}")"
    CUR_MEM="$(smi_memory_for_bus "${PCI_FULL}" || true)"
    [[ -n "${CUR_MEM}" ]] || CUR_MEM="?"

    if [[ "${PROF}" == "unsupported" ]]; then
        COUNT_UNSUPPORTED=$((COUNT_UNSUPPORTED + 1))
        warn "GPU ${PCI_FULL} (10de:${DEVID}) — unlock path not gated for this ID; skipping"
        continue
    fi

    EXP="$(expected_mib_for_profile "${PROF}")"
    GPU_BDFS+=("${PCI_FULL}")
    GPU_DEVIDS+=("${DEVID}")
    GPU_PROFILES+=("${PROF}")
    GPU_EXPECTED+=("${EXP}")
    GPU_CURRENT+=("${CUR_MEM}")

    if [[ "${PROF}" == "8gb" ]]; then
        COUNT_8GB=$((COUNT_8GB + 1))
    else
        COUNT_10GB=$((COUNT_10GB + 1))
    fi

    if [[ "${CUR_MEM}" != "?" ]]; then
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (current ${CUR_MEM} MiB, expect ~${EXP} MiB unlocked)"
    else
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (expect ~${EXP} MiB unlocked)"
    fi
done

[[ ${#GPU_BDFS[@]} -gt 0 ]] || die "No unlockable CMP 170HX GPUs found (need 10de:20c2 and/or 10de:2082)"
if (( COUNT_UNSUPPORTED > 0 )); then
    info "Inventory: ${#GPU_BDFS[@]} unlockable (${COUNT_8GB}× 8gb, ${COUNT_10GB}× 10gb), ${COUNT_UNSUPPORTED} unsupported"
else
    info "Inventory: ${#GPU_BDFS[@]} unlockable (${COUNT_8GB}× 8gb, ${COUNT_10GB}× 10gb)"
fi

step "Selecting card memory profile"
CARD_PROFILE=""
if (( COUNT_8GB > 0 && COUNT_10GB > 0 )); then
    CARD_PROFILE="mixed"
    ok "Mixed variants detected → profile mixed (runtime geometry by PCI ID)"
    if [[ -n "${PROFILE_OVERRIDE}" ]]; then
        warn "--profile=${PROFILE_OVERRIDE} ignored for mixed inventory; card_profile stays mixed (each card unlocks by PCI ID)"
    fi
elif (( COUNT_8GB > 0 )); then
    CARD_PROFILE="8gb"
elif (( COUNT_10GB > 0 )); then
    CARD_PROFILE="10gb"
else
    die "Internal error: no unlockable profiles counted"
fi

if [[ -n "${PROFILE_OVERRIDE}" && "${CARD_PROFILE}" != "mixed" ]]; then
    if [[ "${PROFILE_OVERRIDE}" != "${CARD_PROFILE}" ]]; then
        warn "Inventory is ${CARD_PROFILE} but --profile=${PROFILE_OVERRIDE} was forced (metadata only; geometry follows PCI ID)"
    else
        ok "Profile forced via --profile=${CARD_PROFILE}"
    fi
    CARD_PROFILE="${PROFILE_OVERRIDE}"
fi

case "${CARD_PROFILE}" in
    8gb)
        info "Unlock geometry: 64GB per card (CFG1=0x02779000 LMR=0x0000020B)"
        ;;
    10gb)
        info "Unlock geometry: 40GB per card (CFG1=0x02669000 LMR=0x0000028A)"
        ;;
    mixed)
        info "Unlock geometry: 64GB for 20c2 / 40GB for 2082"
        ;;
    *)
        die "Internal error: bad profile ${CARD_PROFILE}"
        ;;
esac

GPU_INVENTORY_LINES=()
for i in "${!GPU_BDFS[@]}"; do
    GPU_INVENTORY_LINES+=("${GPU_BDFS[$i]} ${GPU_DEVIDS[$i]} ${GPU_PROFILES[$i]} ${GPU_EXPECTED[$i]}")
done
export CMPUNLOCKER_CARD_PROFILE="${CARD_PROFILE}"
CMPUNLOCKER_GPU_INVENTORY="$(printf '%s\n' "${GPU_INVENTORY_LINES[@]}")"
export CMPUNLOCKER_GPU_INVENTORY

step "Verifying nvidia-open (${SUPPORTED_VERSIONS_CSV})"
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
    smi_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
    [[ "${smi_version}" =~ ^[0-9]+(\.[0-9]+)+$ ]] && detected="${smi_version}"
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

if [[ "${P2P_MODE}" == bar1 ]]; then
    info "Checking BAR1 allocation before enabling P2P"
    python3 "${SCRIPT_DIR}/tools/check-bar1.py" || die "BAR1 allocation is not ready for --p2p. Install without --p2p first, cold boot, and follow docs/P2P.md."
fi
info "Removing conflicting NVIDIA DKMS modules (not all systems have any)"
for ver in "${SUPPORTED_VERSIONS[@]}"; do
    dkms remove nvidia/"${ver}" --all 2>/dev/null || true
done
depmod -a "$(uname -r)"
ok "DKMS conflicting modules resolution complete"

step "Building and installing patched modules"
chmod +x "${SCRIPT_DIR}/driver/build.sh"
CMPUNLOCKER_DRIVER_VERSION="${detected}" \
CMPUNLOCKER_CARD_PROFILE="${CARD_PROFILE}" \
CMPUNLOCKER_GPU_INVENTORY="${CMPUNLOCKER_GPU_INVENTORY}" \
CMPUNLOCKER_P2P_MODE="${P2P_MODE}" \
CMPUNLOCKER_DISABLE_GEN2="${DISABLE_GEN2}" \
    "${SCRIPT_DIR}/driver/build.sh"
ok "Patched modules installed (profile ${CARD_PROFILE})"

step "Setting up VM passthrough"
PASSTHROUGH_STATUS="skipped"
if (( CONFIGURE_PASSTHROUGH == 1 )); then
    chmod +x "${SCRIPT_DIR}/tools/passthrough-setup.sh"
    if CMPUNLOCKER_KVER="$(uname -r)" "${SCRIPT_DIR}/tools/passthrough-setup.sh"; then
        PASSTHROUGH_STATUS="armed"
    else
        PASSTHROUGH_STATUS="failed"
        warn "passthrough setup failed; the unlock still works on this host"
    fi
else
    warn "--no-passthrough given; cards are not prepared for VM passthrough"
fi

info "PCIe Gen2 and optional P2P module options were installed with the driver"

for legacy_unit in cmpretrain.service cmp-gen2-retrain.service; do
    systemctl disable --now "${legacy_unit}" 2>/dev/null || true
    systemctl reset-failed "${legacy_unit}" 2>/dev/null || true
done
rm -f /etc/systemd/system/cmpretrain.service \
      /etc/systemd/system/cmp-gen2-retrain.service \
      /usr/local/sbin/retrain.sh \
      /usr/local/sbin/cmp-gen2-retrain.sh
systemctl daemon-reload
ok "Removed legacy PCIe retrain helpers"

if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    chmod +x "${SCRIPT_DIR}/tools/hammer.sh" \
             "${SCRIPT_DIR}/tools/service.sh"
    "${SCRIPT_DIR}/tools/service.sh" install
    ok "Early-boot Gen2 retrain service armed (not started in this session)"
else
    # A previous install may have armed the service. Disable it on reinstall.
    bash "${SCRIPT_DIR}/tools/service.sh" remove
    warn "Early-boot PCIe retraining disabled"
fi

step "Configuring kernel-update rebuilds and NVIDIA package holds"
python3 "${SCRIPT_DIR}/persist/manage.py" install --source "${SCRIPT_DIR}" "${PERSIST_ARGS[@]}"

info "Configuring IOMMU (passthrough)"
IOMMU_STATUS="skipped"
IOMMU_PARAMS=""

iommu_params_for_cpu() {
    local vendor=""
    vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    case "${vendor}" in
        GenuineIntel) echo "intel_iommu=on iommu=pt" ;;
        # amd_iommu= has no "on": the kernel logs "AMD-Vi: Unknown option - 'on'"
        # and ignores it. AMD-Vi enables itself from the BIOS IVRS table, so
        # passthrough mode is all we need to ask for. If the IOMMU stays absent
        # (/sys/class/iommu empty), enable it in BIOS/UEFI — no cmdline token
        # substitutes for that.
        AuthenticAMD) echo "iommu=pt" ;;
        *) echo "" ;;
    esac
}

cmdline_merge() {
    local current="$1"
    local token out=()
    for token in ${current}; do
        case "${token}" in
            intel_iommu=*|amd_iommu=*|iommu=*) continue ;;
            *) out+=("${token}") ;;
        esac
    done
    for token in ${IOMMU_PARAMS}; do
        out+=("${token}")
    done
    echo "${out[*]}"
}

configure_iommu_grub() {
    local grub_file="/etc/default/grub"
    local key="GRUB_CMDLINE_LINUX_DEFAULT"
    local current merged

    grep -q "^${key}=" "${grub_file}" || key="GRUB_CMDLINE_LINUX"
    if grep -q "^${key}=" "${grub_file}"; then
        current="$(sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "${grub_file}" | head -1)"
    else
        current=""
    fi
    merged="$(cmdline_merge "${current}")"

    if [[ "${current}" == "${merged}" ]]; then
        ok "GRUB already has ${IOMMU_PARAMS} (${key})"
        IOMMU_STATUS="already-set"
        return 0
    fi

    cp -a "${grub_file}" "${grub_file}.cmpunlocker.bak"
    if grep -q "^${key}=" "${grub_file}"; then
        local escaped="${merged//\//\\/}"
        sed -i "s/^${key}=.*/${key}=\"${escaped}\"/" "${grub_file}"
    else
        printf '%s="%s"\n' "${key}" "${merged}" >> "${grub_file}"
    fi
    ok "Set ${key}=\"${merged}\" (backup: ${grub_file}.cmpunlocker.bak)"

    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub2-mkconfig &>/dev/null; then
        local cfg="/boot/grub2/grub.cfg"
        local efi_cfg
        efi_cfg="$(ls /boot/efi/EFI/*/grub.cfg 2>/dev/null | head -1 || true)"
        [[ -n "${efi_cfg}" ]] && cfg="${efi_cfg}"
        grub2-mkconfig -o "${cfg}"
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        warn "No grub config generator found — regenerate grub.cfg manually"
        IOMMU_STATUS="needs-grub-regen"
        return 0
    fi
    ok "Regenerated GRUB config"
    IOMMU_STATUS="configured"
}

configure_iommu_kernel_cmdline() {
    local file="/etc/kernel/cmdline"
    local current merged
    current="$(tr -d '\n' < "${file}")"
    merged="$(cmdline_merge "${current}")"

    if [[ "${current}" == "${merged}" ]]; then
        ok "${file} already has ${IOMMU_PARAMS}"
        IOMMU_STATUS="already-set"
        return 0
    fi

    cp -a "${file}" "${file}.cmpunlocker.bak"
    printf '%s\n' "${merged}" > "${file}"
    ok "Set ${file} to \"${merged}\" (backup: ${file}.cmpunlocker.bak)"

    if command -v kernel-install &>/dev/null && [[ -d /boot/loader/entries ]]; then
        for kdir in /lib/modules/*/; do
            kver="$(basename "${kdir}")"
            [[ -f "${kdir}/vmlinuz" ]] || continue
            kernel-install add "${kver}" "${kdir}/vmlinuz" 2>/dev/null || true
        done
        ok "Refreshed systemd-boot entries"
        IOMMU_STATUS="configured"
    else
        warn "Update your boot entries so ${file} takes effect"
        IOMMU_STATUS="needs-boot-refresh"
    fi
}

if (( CONFIGURE_IOMMU == 0 )); then
    warn "--no-iommu given; leaving kernel command line untouched"
else
    IOMMU_PARAMS="$(iommu_params_for_cpu)"
    if [[ -z "${IOMMU_PARAMS}" ]]; then
        warn "Unrecognized CPU vendor — cannot pick IOMMU kernel parameters; skipping"
    elif [[ -f /etc/default/grub ]]; then
        info "Target: ${IOMMU_PARAMS} (GRUB)"
        configure_iommu_grub
    elif [[ -f /etc/kernel/cmdline ]]; then
        info "Target: ${IOMMU_PARAMS} (systemd-boot)"
        configure_iommu_kernel_cmdline
    else
        warn "No /etc/default/grub or /etc/kernel/cmdline found"
        warn "Add these to your kernel command line manually: ${IOMMU_PARAMS}"
        IOMMU_STATUS="manual"
    fi

    if grep -qw iommu=pt /proc/cmdline 2>/dev/null && [[ -d /sys/class/iommu ]] && [[ -n "$(ls -A /sys/class/iommu 2>/dev/null)" ]]; then
        ok "IOMMU is already active in passthrough mode on the running kernel"
    elif [[ "${IOMMU_STATUS}" != "skipped" ]]; then
        info "IOMMU passthrough takes effect after the next reboot"
        warn "IOMMU must also be enabled in BIOS/UEFI (VT-d / AMD-Vi / SVM)"
    fi
fi

step "Done"
banner
echo "cmpunlocker install finished!"
echo "Profile: ${CARD_PROFILE}  |  ${#GPU_BDFS[@]} GPU(s): ${COUNT_8GB}× 8gb, ${COUNT_10GB}× 10gb"
echo "Passthrough: ${PASSTHROUGH_STATUS}"
if [[ "${P2P_MODE}" != off ]]; then
    echo "P2P: experimental ${P2P_MODE} path enabled; verify with tools/p2p-test.cu after cold boot"
fi
if [[ "${P2P_MODE}" == bar1 ]]; then
    echo "Full BAR1 allocation may require the separate kernel-patches/; see docs/P2P.md"
fi
if [[ -n "${IOMMU_PARAMS}" && "${IOMMU_STATUS}" != "skipped" ]]; then
    echo "IOMMU:   ${IOMMU_PARAMS} (${IOMMU_STATUS})"
else
    echo "IOMMU:   not configured"
fi
echo ""
echo "Per-GPU expectations after unlock:"
printf "  %-16s %-8s %-8s %s\n" "BDF" "PCI ID" "Variant" "Expect MiB"
for i in "${!GPU_BDFS[@]}"; do
    printf "  %-16s %-8s %-8s ~%s\n" "${GPU_BDFS[$i]}" "${GPU_DEVIDS[$i]}" "${GPU_PROFILES[$i]}" "${GPU_EXPECTED[$i]}"
done
echo ""
echo "Next:"
echo -e "  1. Cold reboot recommended: ${CYAN}sudo shutdown -h now${NC}  (then power on)"
echo -e "  2. Verify all GPUs: ${CYAN}sudo ./verify.sh${NC}"
if (( DISABLE_GEN2 == 0 )); then
    echo -e "  3. Verify PCIe Gen2: ${CYAN}nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max --format=csv${NC}  (expect 2,2)"
else
    echo "  3. Gen2 retraining disabled; the link keeps its firmware speed."
fi
echo -e "  4. Or check manually: ${CYAN}nvidia-smi${NC}"
echo -e "  5. Unlock logs: ${CYAN}sudo dmesg | grep SEC2_DEBUG${NC}"
echo -e "  6. Verify IOMMU after reboot: ${CYAN}cat /proc/cmdline${NC} and ${CYAN}ls /sys/class/iommu${NC}"
if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    echo -e "  7. Verify negotiated Gen2: ${CYAN}sudo ./tools/service.sh verify${NC}"
    echo -e "     Recovery boot option: ${CYAN}systemd.mask=gen2.service${NC}"
fi
echo ""
echo "Rebuild status: sudo python3 /usr/lib/cmpunlocker/manage.py status"
echo "Manual rebuild: sudo python3 /usr/lib/cmpunlocker/manage.py rebuild"
echo "Log saved to: ${LOG_FILE}"
echo ""
