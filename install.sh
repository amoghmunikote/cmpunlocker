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
for arg in "$@"; do
    case "${arg}" in
        --profile=8gb|--profile=8GB) PROFILE_OVERRIDE="8gb" ;;
        --profile=10gb|--profile=10GB) PROFILE_OVERRIDE="10gb" ;;
        --profile=es|--profile=ES) PROFILE_OVERRIDE="es" ;;
        --no-iommu) CONFIGURE_IOMMU=0 ;;
        --no-gen2-service) CONFIGURE_GEN2_SERVICE=0 ;;
        --no-passthrough) CONFIGURE_PASSTHROUGH=0 ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./install.sh [--profile=8gb|10gb|es] [--no-iommu] [--no-gen2-service]
                        [--no-passthrough]

  --profile=8gb   Force 8GB metadata label (geometry is still chosen per PCI ID)
  --profile=10gb  Force 10GB metadata label (geometry is still chosen per PCI ID)
  --profile=es    ES / single-rank variant: label and verify as a 32GB unlock
                  (detected automatically; this only forces it)
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

ES cards report 10de:20c2 as well, so they cannot be told apart by PCI ID. The
installer reads each GPU floorsweep register over BAR0 (read-only) and reclassifies
the ones carrying the single-rank signature as es / 32GB unlock.

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
step_init 7

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

DETECTED_VARIANTS=()
if command -v python3 &>/dev/null; then
    PROBE_BDFS=()
    for PCI_LINE in "${PCI_LINES[@]}"; do
        PROBE_BDFS+=("$(normalize_bus_id "$(echo "${PCI_LINE}" | awk '{print $1}')")")
    done
    mapfile -t DETECTED_VARIANTS < <(python3 "${SCRIPT_DIR}/tools/detect-variant.py" \
        "${SCRIPT_DIR}/common/constants.yaml" "${PROBE_BDFS[@]}" 2>/dev/null || true)
else
    warn "python3 not found; cannot read the floorsweep signature to spot ES cards"
fi

variant_for_bus() {
    local want="$1" line
    for line in ${DETECTED_VARIANTS[@]+"${DETECTED_VARIANTS[@]}"}; do
        if [[ "${line%% *}" == "${want}" ]]; then
            echo "${line##* }"
            return 0
        fi
    done
}

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()
GPU_CURRENT=()
COUNT_8GB=0
COUNT_10GB=0
COUNT_ES=0
COUNT_UNSUPPORTED=0

for PCI_LINE in "${PCI_LINES[@]}"; do
    PCI="$(echo "${PCI_LINE}" | awk '{print $1}')"
    PCI_FULL="$(normalize_bus_id "${PCI}")"
    DEVID="$(echo "${PCI_LINE}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
    PROF="$(profile_from_devid "${DEVID}")"
    DETECTED="$(variant_for_bus "${PCI_FULL}")"
    PROF_NOTE=""
    if [[ "${PROF}" != "unsupported" ]]; then
        if [[ "${PROFILE_OVERRIDE}" == "es" ]]; then
            PROF="es"
        elif [[ -z "${PROFILE_OVERRIDE}" && -n "${DETECTED}" ]]; then
            PROF="${DETECTED}"
            PROF_NOTE=", detected from floorsweep"
        elif [[ -n "${PROFILE_OVERRIDE}" && -n "${DETECTED}" \
                && "${PROFILE_OVERRIDE}" != "${DETECTED}" ]]; then
            warn "GPU ${PCI_FULL} matches the ${DETECTED} signature but --profile=${PROFILE_OVERRIDE} was given"
        fi
    fi
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

    case "${PROF}" in
        8gb) COUNT_8GB=$((COUNT_8GB + 1)) ;;
        es)  COUNT_ES=$((COUNT_ES + 1)) ;;
        *)   COUNT_10GB=$((COUNT_10GB + 1)) ;;
    esac

    if [[ "${CUR_MEM}" != "?" ]]; then
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (current ${CUR_MEM} MiB, expect ~${EXP} MiB unlocked${PROF_NOTE})"
    else
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (expect ~${EXP} MiB unlocked${PROF_NOTE})"
    fi
done

[[ ${#GPU_BDFS[@]} -gt 0 ]] || die "No unlockable CMP 170HX GPUs found (need 10de:20c2 and/or 10de:2082)"
INVENTORY_PARTS=()
if (( COUNT_8GB > 0 )); then INVENTORY_PARTS+=("${COUNT_8GB}× 8gb"); fi
if (( COUNT_10GB > 0 )); then INVENTORY_PARTS+=("${COUNT_10GB}× 10gb"); fi
if (( COUNT_ES > 0 )); then INVENTORY_PARTS+=("${COUNT_ES}× es"); fi
INVENTORY_BREAKDOWN="$(IFS=", "; echo "${INVENTORY_PARTS[*]}")"
if (( COUNT_UNSUPPORTED > 0 )); then
    info "Inventory: ${#GPU_BDFS[@]} unlockable (${INVENTORY_BREAKDOWN}), ${COUNT_UNSUPPORTED} unsupported"
else
    info "Inventory: ${#GPU_BDFS[@]} unlockable (${INVENTORY_BREAKDOWN})"
fi

step "Selecting card memory profile"
CARD_PROFILE=""
if (( COUNT_ES > 0 && COUNT_8GB + COUNT_10GB > 0 )); then
    CARD_PROFILE="mixed"
    ok "ES and standard variants in one box → profile mixed (runtime geometry per card)"
elif (( COUNT_ES > 0 )); then
    CARD_PROFILE="es"
    if [[ "${PROFILE_OVERRIDE}" == "es" ]]; then
        ok "ES / single-rank variant forced via --profile=es"
    else
        ok "ES / single-rank variant detected from the floorsweep signature"
    fi
elif (( COUNT_8GB > 0 && COUNT_10GB > 0 )); then
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

if [[ -n "${PROFILE_OVERRIDE}" && "${PROFILE_OVERRIDE}" != "es" \
      && "${CARD_PROFILE}" != "mixed" ]]; then
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
    es)
        info "Unlock geometry: 32GB per card (CFG1=0x02779000 LMR=0x0000020A)"
        info "Chosen at runtime from the single-rank floorsweep signature"
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
export CMPUNLOCKER_GPU_INVENTORY="$(printf '%s\n' "${GPU_INVENTORY_LINES[@]}")"

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

info "Configuring PCIe Gen2"
cat > /etc/modprobe.d/cmp-pcie-gen2.conf <<'EOF'
options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"
EOF
ok "Wrote /etc/modprobe.d/cmp-pcie-gen2.conf"

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
    warn "--no-gen2-service given; early-boot PCIe retraining is not installed"
fi

info "Configuring IOMMU (passthrough)"
IOMMU_STATUS="skipped"
IOMMU_PARAMS=""

iommu_params_for_cpu() {
    local vendor=""
    vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    case "${vendor}" in
        GenuineIntel) echo "intel_iommu=on iommu=pt" ;;
        AuthenticAMD) echo "amd_iommu=on iommu=pt" ;;
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
echo "Profile: ${CARD_PROFILE}  |  ${#GPU_BDFS[@]} GPU(s): ${INVENTORY_BREAKDOWN}"
echo "Passthrough: ${PASSTHROUGH_STATUS}"
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
echo -e "  3. Verify PCIe Gen2: ${CYAN}nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max --format=csv${NC}  (expect 2,2)"
echo -e "  4. Or check manually: ${CYAN}nvidia-smi${NC}"
echo -e "  5. Unlock logs: ${CYAN}sudo dmesg | grep SEC2_DEBUG${NC}"
echo -e "  6. Verify IOMMU after reboot: ${CYAN}cat /proc/cmdline${NC} and ${CYAN}ls /sys/class/iommu${NC}"
if (( CONFIGURE_GEN2_SERVICE == 1 )); then
    echo -e "  7. Verify negotiated Gen2: ${CYAN}sudo ./tools/service.sh verify${NC}"
    echo -e "     Recovery boot option: ${CYAN}systemd.mask=gen2.service${NC}"
fi
echo ""
echo "This script removed the nvidia DKMS kernel modules. You will need to re-run this script after each kernel upgrade"
echo "Log saved to: ${LOG_FILE}"
echo ""
