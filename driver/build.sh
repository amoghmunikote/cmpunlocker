#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/VERSION")
DEFAULT_VERSION="${SUPPORTED_VERSIONS[0]:-}"
VERSION="${CMPUNLOCKER_DRIVER_VERSION:-${DEFAULT_VERSION}}"
PATCH_DIR="${SCRIPT_DIR}/patches"
BUILD_ROOT="${CMPUNLOCKER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
SRC_NAME="open-gpu-kernel-modules-${VERSION}"
SRC_DIR="${BUILD_ROOT}/${SRC_NAME}"
TARBALL="${BUILD_ROOT}/${SRC_NAME}.tar.gz"
TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VERSION}.tar.gz"
KVER="${CMPUNLOCKER_KVER:-$(uname -r)}"
[[ "${KVER}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || { echo "Invalid kernel version" >&2; exit 1; }
KSRC="/lib/modules/${KVER}/build"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ${SCRIPT_DIR}/build.sh"
[[ -n "${VERSION}" ]] || die "No driver version set (driver/VERSION empty and CMPUNLOCKER_DRIVER_VERSION unset)"
version_supported "${VERSION}" || die "Unsupported driver version '${VERSION}' (supported: ${SUPPORTED_VERSIONS[*]})"
[[ -d "${PATCH_DIR}" ]] || die "Missing patches directory: ${PATCH_DIR}"
[[ -d "${KSRC}" ]] || die "Kernel headers not found at ${KSRC}. Install linux-headers-${KVER} (or kernel-devel)."
command -v python3 &>/dev/null || die "python3 is required to apply the card memory profile"
python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML is required to read common/constants.yaml (apt install python3-yaml)"
command -v sha256sum &>/dev/null || die "sha256sum is required"
info "Building against open-gpu-kernel-modules ${VERSION}"

PATCH_ORDER=(
    sec2-postbl-plm-ss-cfg.patch
    booter-verify.patch
    late-pma.patch
    bar0-pramin-clamp.patch
    ce-scrub-workarounds.patch
    cmp-scrub-timeout.patch
    persistent-sw-state.patch
    name-string.patch
    bar1-resize-unlock.patch
    cmp-sku-mask.patch
)
GEN2_PATCH_ORDER=(
    pcie-gen2.patch
    pcie-gen2-probe-retrain.patch
)
P2P_COMMON_PATCH_ORDER=(
    p2p-caps.patch
)
P2P_BAR1_PATCH_ORDER=(
    p2p-bar1.patch
    p2p-skip-mailbox.patch
    p2p-read-cap.patch
)
P2P_MAILBOX_PATCH_ORDER=(
    p2p-mailbox.patch
)
P2P_MODE="${CMPUNLOCKER_P2P_MODE:-${CMPUNLOCKER_ENABLE_P2P:-off}}"
DISABLE_GEN2="${CMPUNLOCKER_DISABLE_GEN2:-0}"
case "${DISABLE_GEN2}" in
    0) PATCH_ORDER+=("${GEN2_PATCH_ORDER[@]}") ;;
    1) info "Gen2 retraining disabled; preserving firmware link speed" ;;
    *) die "CMPUNLOCKER_DISABLE_GEN2 must be 0 or 1" ;;
esac
case "${P2P_MODE}" in
    0|off) P2P_MODE=off; info "P2P overrides disabled" ;;
    1|bar1)
        P2P_MODE=bar1
        PATCH_ORDER+=("${P2P_COMMON_PATCH_ORDER[@]}" "${P2P_BAR1_PATCH_ORDER[@]}") ;;
    mailbox) PATCH_ORDER+=("${P2P_COMMON_PATCH_ORDER[@]}" "${P2P_MAILBOX_PATCH_ORDER[@]}") ;;
    *) die "CMPUNLOCKER_P2P_MODE must be off, bar1 or mailbox" ;;
esac
info "P2P transport: ${P2P_MODE}"
PATCH_FILES=()
for name in "${PATCH_ORDER[@]}"; do
    p="${PATCH_DIR}/${name}"
    [[ -f "${p}" ]] || die "Missing patch: ${p}"
    PATCH_FILES+=("${p}")
done
PATCH_HASH="$(cat "${PATCH_FILES[@]}" | sha256sum | cut -d' ' -f1)"

PROFILE="${CMPUNLOCKER_CARD_PROFILE:-8gb}"
case "${PROFILE}" in
    8GB) PROFILE="8gb" ;;
    10GB) PROFILE="10gb" ;;
    MIXED) PROFILE="mixed" ;;
esac

CONSTANTS="${SCRIPT_DIR}/../common/constants.yaml"
[[ -r "${CONSTANTS}" ]] || die "Missing ${CONSTANTS}"
CONSTANTS_ENV="$(python3 "${SCRIPT_DIR}/../tools/read-constants.py" "${CONSTANTS}" "${PATCH_DIR}" "${SCRIPT_DIR}/build.sh" "${PROFILE}")" || die "common/constants.yaml rejected (see error above)"
eval "${CONSTANTS_ENV}"

BUILD_STAMP="${VERSION}:${KVER}:${PROFILE}:p2p=${P2P_MODE}:no-gen2=${DISABLE_GEN2}:${PATCH_HASH}:$(cat "${SCRIPT_DIR}/build.sh" "${CONSTANTS}" "${SCRIPT_DIR}/../tools/module-options.sh" | sha256sum | cut -d' ' -f1)"

mkdir -p "${BUILD_ROOT}"

if [[ ! -f "${TARBALL}" ]]; then
    info "Downloading open-gpu-kernel-modules ${VERSION}..."
    curl -L --fail -o "${TARBALL}.partial" "${TARBALL_URL}"
    mv "${TARBALL}.partial" "${TARBALL}"
    ok "Downloaded ${TARBALL}"
else
    ok "Using cached tarball ${TARBALL}"
fi

STAMP_FILE="${SRC_DIR}/.cmpunlocker-stamp"
if [[ -d "${SRC_DIR}" ]] && [[ "$(cat "${STAMP_FILE}" 2>/dev/null || true)" == "${BUILD_STAMP}" ]]; then
    SKIP_PREP=1
    ok "Source tree already extracted and patched for this exact build; reusing it"
else
    SKIP_PREP=0
    info "Extracting sources..."
    rm -rf "${SRC_DIR}"
    tar -xzf "${TARBALL}" -C "${BUILD_ROOT}"
    if [[ ! -d "${SRC_DIR}" ]]; then
        extracted="$(find "${BUILD_ROOT}" -maxdepth 1 -type d -name "${SRC_NAME}*" | head -1)"
        [[ -n "${extracted}" ]] || die "Extracted source tree not found"
        mv "${extracted}" "${SRC_DIR}"
    fi
    ok "Sources ready: ${SRC_DIR}"

    info "Applying unlock patches..."
    cd "${SRC_DIR}"
    for i in "${!PATCH_ORDER[@]}"; do
        info "  ${PATCH_ORDER[$i]}"
        patch --batch --forward --fuzz=0 -p1 < "${PATCH_FILES[$i]}"
    done
    ok "All patches applied"

    GSP_C="${SRC_DIR}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
    [[ -f "${GSP_C}" ]] || die "Missing ${GSP_C} after patching"

    info "Applying memory profile ${PROFILE} (${UNLOCK_LABEL} geometry)..."
    if [[ "${SKIP_GEOMETRY_REWRITE}" -eq 1 ]]; then
        info "mixed profile: runtime device-id geometry (no build-time CFG1/LMR rewrite)"
    else
        python3 - "${GSP_C}" "${CFG1}" "${LMR}" "${FB_BYTES}" "${UNLOCK_LABEL}" <<'PY'
import pathlib, re, sys
path, cfg1, lmr, fb, label = sys.argv[1:6]
text = pathlib.Path(path).read_text()
if (
    "SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID" in text
    and "SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID" in text
    and "0x02779000U" in text
    and "0x02669000U" in text
    and "0x0000001000000000ULL" in text
    and "0x0000000A00000000ULL" in text
):
    print(f"runtime device-id geometry (profile metadata={label})")
    raise SystemExit(0)

text2, n1 = re.subn(
    r"(NvU32 cfg1Value = )0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{cfg1}\g<2>",
    text,
    count=1,
)
text2, n2 = re.subn(
    r"(NvU32 lmrValue\s*=\s*)0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{lmr}\g<2>",
    text2,
    count=1,
)
text2, n3 = re.subn(
    r"(NvU64 targetFbBytes = )0x[0-9A-Fa-f]+ULL;\s*/\*[^*]*\*/",
    rf"\g<1>{fb}ULL;  /* {label} */",
    text2,
    count=1,
)
if n1 != 1 or n2 != 1 or n3 != 1:
    raise SystemExit(
        f"geometry rewrite failed (cfg1={n1} lmr={n2} fb={n3}); check kernel_gsp.c markers"
    )
pathlib.Path(path).write_text(text2)
print(f"cfg1={cfg1} lmr={lmr} fb={fb} ({label})")
PY
    fi
    ok "Memory profile ${PROFILE}: unlock_geometry=${UNLOCK_LABEL}"

    printf '%s\n' "${BUILD_STAMP}" > "${STAMP_FILE}"
fi

cd "${SRC_DIR}"
info "Building modules for kernel ${KVER}..."
find . -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
if [[ "${SKIP_PREP}" -eq 0 ]]; then
    rm -rf src/nvidia/_out src/nvidia-modeset/_out kernel-open/conftest 2>/dev/null || true
else
    info "Reusing prior build output — incremental rebuild"
fi

JOBS="$(nproc)"
CC_CMD="gcc"
if command -v ccache &>/dev/null; then
    CC_CMD="ccache gcc"
    info "ccache detected — compiler output will be cached for faster rebuilds"
fi
make -j"${JOBS}" modules SYSSRC="${KSRC}" CC="${CC_CMD}"
ok "Modules built"
if command -v ccache &>/dev/null; then
    ccache -s 2>/dev/null | sed 's/^/  /' || true
fi
info "Installing modules to ${INSTALL_MOD_DIR}..."
mkdir -p "${INSTALL_MOD_DIR}"

mapfile -t KO_FILES < <(find "${SRC_DIR}" -type f \( \
    -name 'nvidia.ko' -o -name 'nvidia-modeset.ko' -o -name 'nvidia-uvm.ko' \
    -o -name 'nvidia-drm.ko' -o -name 'nvidia-peermem.ko' \) \
    ! -path '*/conftest/*' | sort -u)
[[ -f "${SRC_DIR}/kernel-open/nvidia.ko" ]] || die "Core nvidia.ko was not built"

for ko in "${KO_FILES[@]}"; do
    base="$(basename "${ko}")"
    install -m 0644 "${ko}" "${INSTALL_MOD_DIR}/${base}"
    ok "Installed ${base}"
done

if [[ "${CMPUNLOCKER_BUILD_PASSTHROUGH:-0}" == 1 ]]; then
    PT_BUILD="${BUILD_ROOT}/passthrough-${KVER}"
    mkdir -p "${PT_BUILD}"
    cp "${SCRIPT_DIR}/passthrough/Makefile" "${SCRIPT_DIR}/passthrough/cmp_no_bus_reset.c" "${PT_BUILD}/"
    make -C "${PT_BUILD}" KVER="${KVER}"
    install -m 0644 "${PT_BUILD}/cmp_no_bus_reset.ko" "${INSTALL_MOD_DIR}/cmp_no_bus_reset.ko"
fi

printf '%s\n' "${VERSION}" > "${INSTALL_MOD_DIR}/driver_version"
printf '%s\n' "${PROFILE}" > "${INSTALL_MOD_DIR}/card_profile"
printf '%s\n' "${UNLOCK_LABEL}" > "${INSTALL_MOD_DIR}/unlock_geometry"
printf '%s\n' "${CMPUNLOCKER_GPU_INVENTORY:-}" > "${INSTALL_MOD_DIR}/gpu_inventory"
printf '%s\n' "${P2P_MODE}" > "${INSTALL_MOD_DIR}/p2p_mode"
printf '%s\n' "${DISABLE_GEN2}" > "${INSTALL_MOD_DIR}/gen2_disabled"
[[ "${P2P_MODE}" == off ]] && enabled=0 || enabled=1
printf '%s\n' "${enabled}" > "${INSTALL_MOD_DIR}/p2p_enabled"
info "Configuring NVIDIA module options before rebuilding initramfs"
mkdir -p /etc/modprobe.d /etc/depmod.d
bash "${SCRIPT_DIR}/../tools/module-options.sh" "${P2P_MODE}" "${DISABLE_GEN2}" > /etc/modprobe.d/cmp-pcie-gen2.conf
install -m 0644 "${SCRIPT_DIR}/../persist/depmod-cmpunlocker.conf" /etc/depmod.d/cmpunlocker.conf
install -m 0644 "${SCRIPT_DIR}/../persist/modprobe-cmpunlocker.conf" /etc/modprobe.d/cmpunlocker.conf

depmod -a "${KVER}"
sync
ok "depmod complete"
rebuild_initramfs() {
    if command -v update-initramfs &>/dev/null; then
        info "Rebuilding initramfs (update-initramfs)..."
        update-initramfs -u -k "${KVER}" || return 1
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v dracut &>/dev/null; then
        info "Rebuilding initramfs (dracut)..."
        dracut --force --kver "${KVER}" || return 1
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v mkinitcpio &>/dev/null; then
        info "Rebuilding initramfs (mkinitcpio)..."
        mkinitcpio -P || return 1
        ok "initramfs rebuilt"
        return 0
    fi
    warn "No initramfs tool found — rebuild manually before rebooting"
    return 1
}

rebuild_initramfs || die "Modules installed, but initramfs was not rebuilt; fix this before rebooting"
resolved="$(modinfo -n -k "${KVER}" nvidia 2>/dev/null || true)"
if [[ -n "${resolved}" ]]; then
    info "modprobe will load: ${resolved}"
    if [[ "${resolved}" != *"/updates/cmpunlocker/"* ]]; then
        die "Resolved nvidia.ko is not under updates/cmpunlocker/ for ${KVER}"
    fi
fi
[[ -n "${resolved}" ]] || die "Cannot resolve nvidia.ko for ${KVER}"
echo ""
ok "Modules and boot options installed. The running driver has not been reloaded."
info "Power off and power on to activate: sudo shutdown -h now"
echo ""
