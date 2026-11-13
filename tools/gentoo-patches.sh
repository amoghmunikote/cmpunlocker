#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIVER_DIR="${PROJECT_DIR}/driver"
PATCH_DIR="${DRIVER_DIR}/patches"
VERSION_FILE="${DRIVER_DIR}/VERSION"
BUILD_SH="${DRIVER_DIR}/build.sh"
BUILD_CACHE_DIR="${DRIVER_DIR}/.build"
MANIFEST_NAME=".cmpunlocker-manifest"

source "${PROJECT_DIR}/common/lib.sh"

CATEGORY="x11-drivers"
PN="nvidia-drivers"
MODULE_SUBDIR="kernel-module-source"
VERSION=""
PROFILE="8gb"
SOURCE="auto"
VERIFY="auto"
DRY_RUN=0
DO_UNINSTALL=0
DEST=""
EXTRA_DISTDIR=""

usage() {
    cat <<EOF
Usage:
  sudo $0 [--version=PV] [--profile=8gb|10gb|mixed] [options]
  sudo $0 --uninstall [--version=PV]

Generate the cmpunlocker patch set as Portage user patches so that
x11-drivers/nvidia-drivers builds the unlocked kernel modules itself, and
install them into /etc/portage/patches/${CATEGORY}/${PN}-<PV>/.

Options:
  --version=PV         nvidia-drivers version to target (default: first entry
                       in driver/VERSION)
  --profile=P          8gb|10gb|mixed (default: 8gb). With the current patch
                       set geometry is runtime-selected by PCI device id, so
                       the profile only matters if a future patch set falls
                       back to build-time geometry.
  --category=CAT       Portage category (default: ${CATEGORY})
  --pn=NAME            Portage package name (default: ${PN})
  --module-subdir=NAME Directory under \${S} where the ebuild keeps the open
                       kernel-module sources (default: ${MODULE_SUBDIR})
  --dest=DIR           Override the /etc/portage/patches target directory
                       (for testing; manifest handling still applies)
  --distdir=DIR        Extra directory to search for the
                       NVIDIA-kernel-module-source-<PV>.tar.xz distfile
                       (default: portageq envvar DISTDIR, then
                       /var/cache/distfiles)
  --source=auto|distdir|github
                       Which pristine source tree to verify against:
                       distdir = DISTDIR/NVIDIA-kernel-module-source-<PV>.tar.xz
                       github  = open-gpu-kernel-modules-<PV>.tar.gz (downloads)
                       auto    = distdir if cached, else github (default)
  --no-verify          Skip patch-set verification (not recommended)
  --dry-run            Show what would be installed; touch nothing in /etc
  --uninstall          Remove the files this script installed (manifest-based)

The patches are applied by Portage (EAPI >= 7) with:
  patch -p1 -f -g0    from \${S} (=\${WORKDIR}), in LC_ALL=C basename order,
after the ebuild's own patches and after the ebuild has renamed the kernel
module sources to ${MODULE_SUBDIR}/. Filenames are numbered to preserve the
order from driver/build.sh.
EOF
}

die_usage() { err "$*"; echo ""; usage; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version=*) VERSION="${1#*=}" ;;
        --profile=*) PROFILE="${1#*=}" ;;
        --category=*) CATEGORY="${1#*=}" ;;
        --pn=*) PN="${1#*=}" ;;
        --module-subdir=*) MODULE_SUBDIR="${1#*=}" ;;
        --dest=*) DEST="${1#*=}" ;;
        --distdir=*) EXTRA_DISTDIR="${1#*=}" ;;
        --source=*) SOURCE="${1#*=}" ;;
        --no-verify) VERIFY="no" ;;
        --dry-run) DRY_RUN=1 ;;
        --uninstall) DO_UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "Unknown argument: $1" ;;
    esac
    shift
done

case "${PROFILE}" in
    8GB) PROFILE="8gb" ;;
    10GB) PROFILE="10gb" ;;
    MIXED) PROFILE="mixed" ;;
esac
case "${PROFILE}" in
    8gb|10gb|mixed) ;;
    *) die_usage "Unknown profile '${PROFILE}' (use 8gb, 10gb or mixed)" ;;
esac
case "${SOURCE}" in
    auto|distdir|github) ;;
    *) die_usage "Unknown --source '${SOURCE}'" ;;
esac
[[ -n "${VERSION}" ]] || VERSION="$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${VERSION_FILE}" | head -1)"
[[ -n "${VERSION}" ]] || die "No driver version: pass --version= or fill driver/VERSION"
grep -E "^${VERSION}$" "${VERSION_FILE}" >/dev/null \
    || die "Driver version ${VERSION} is not in driver/VERSION ($(grep -sE '^[0-9.]+' "${VERSION_FILE}" | tr '\n' ' '))"

if [[ -z "${DEST}" ]]; then
    DEST="/etc/portage/patches/${CATEGORY}/${PN}-${VERSION}"
fi

# ---------------------------------------------------------------------------
# Uninstall mode: delete exactly the files listed in our manifest.
# ---------------------------------------------------------------------------
if (( DO_UNINSTALL )); then
    manifest="${DEST}/${MANIFEST_NAME}"
    [[ -d "${DEST}" ]] || { ok "Nothing to uninstall: ${DEST} does not exist"; exit 0; }
    if [[ -f "${manifest}" ]]; then
        mapfile -t files < <(grep -v '^[[:space:]]*$' "${manifest}")
        for f in "${files[@]}"; do
            [[ "${f}" == */* ]] && die "Malformed manifest entry: ${f}"
            if (( DRY_RUN )); then
                info "[dry-run] would remove ${DEST}/${f}"
            else
                rm -f -- "${DEST}/${f}"
            fi
        done
        (( DRY_RUN )) || rm -f -- "${manifest}"
        ok "Removed ${#files[@]} cmpunlocker patch file(s) from ${DEST}"
    else
        die "No ${MANIFEST_NAME} in ${DEST} — refusing to remove files we did not install"
    fi
    # Drop the directory when it became empty; leave it otherwise (user's own patches).
    if [[ -z "$(ls -A -- "${DEST}" 2>/dev/null || true)" ]]; then
        (( DRY_RUN )) || rmdir -- "${DEST}"
        info "Removed empty directory ${DEST}"
    fi
    info "Re-emerge ${CATEGORY}/${PN}-${VERSION} (or remove the stale build) to get stock modules back."
    exit 0
fi

# ---------------------------------------------------------------------------
# Read the canonical patch order from driver/build.sh (same source of truth
# as tools/read-constants.py).
# ---------------------------------------------------------------------------
mapfile -t PATCH_ORDER < <(awk '/^PATCH_ORDER=\(/{f=1;next} /^\)/{f=0} f' "${BUILD_SH}" \
    | tr -d ' \t\r' | grep -E '\.patch$' || true)
[[ ${#PATCH_ORDER[@]} -gt 0 ]] || die "PATCH_ORDER not found in ${BUILD_SH}"
for name in "${PATCH_ORDER[@]}"; do
    [[ -f "${PATCH_DIR}/${name}" ]] || die "Missing patch: ${PATCH_DIR}/${name}"
done
# per-version compatibility patches (driver/patches/<PV>/*.patch), staged and
# numbered right after the common set — e.g. the Linux 7.3 dmem_cgroup_init
# conftest port that only 615.71.09 needs
if [[ -d "${PATCH_DIR}/${VERSION}" ]]; then
    for extra in "${PATCH_DIR}/${VERSION}"/*.patch; do
        [[ -e "${extra}" ]] || continue
        PATCH_ORDER+=("$(basename "${extra}")")
    done
fi
# resolve a patch name in PATCH_ORDER to its file (common set, or the
# per-version subdirectory driver/patches/<PV>/)
patch_src() {
    [[ -f "${PATCH_DIR}/${1}" ]] && { echo "${PATCH_DIR}/${1}"; return; }
    echo "${PATCH_DIR}/${VERSION}/${1}"
}

TMPROOT="$(mktemp -d /tmp/cmpunlocker-gentoo.XXXXXX)"
trap 'rm -rf "${TMPROOT}"' EXIT
STAGE="${TMPROOT}/stage"
mkdir -p "${STAGE}"

# ---------------------------------------------------------------------------
# Stage the numbered patches with headers rewritten to the Portage layout:
#   a/src/...  ->  a/kernel-module-source/src/...
# ---------------------------------------------------------------------------
info "Staging ${#PATCH_ORDER[@]} patch(es) for ${CATEGORY}/${PN}-${VERSION}"

# Header-rewrite program: reads a cmpunlocker patch on stdin, writes the
# Portage-layout version on stdout: strip level stays -p1, paths gain the
# module-subdir prefix. Kept in a file so the patch file can stay on stdin.
REWRITE_PY="${TMPROOT}/rewrite_headers.py"
cat > "${REWRITE_PY}" <<'PY'
import re, sys
mod = sys.argv[1]
hdr = re.compile(r"^(diff (?:-Naur|--git) )a/(\S+)( b/)(\S+)(.*)$")
old = re.compile(r"^--- a/(\S+)(.*)$")
new = re.compile(r"^\+\+\+ b/(\S+)(.*)$")
for line in sys.stdin:
    nl = line.endswith("\n")
    s = line[:-1] if nl else line
    m = hdr.match(s)
    if m:
        s = "%sa/%s/%s%sb/%s/%s%s" % (m[1], mod, m[2], m[3], mod, m[4], m[5])
    else:
        m = old.match(s)
        if m:
            s = "--- a/%s/%s%s" % (mod, m[1], m[2])
        else:
            m = new.match(s)
            if m:
                s = "+++ b/%s/%s%s" % (mod, m[1], m[2])
    sys.stdout.write((s + "\n") if nl else s)
PY

STAGED_FILES=()
i=0
for name in "${PATCH_ORDER[@]}"; do
    i=$((i + 1))
    numbered="$(printf '%02d-%s' "${i}" "${name}")"
    python3 "${REWRITE_PY}" "${MODULE_SUBDIR}" < "$(patch_src "${name}")" > "${STAGE}/${numbered}"
    [[ -s "${STAGE}/${numbered}" ]] || die "Staged patch ${numbered} is empty"
    STAGED_FILES+=("${numbered}")
done
ok "Staged: ${STAGED_FILES[*]}"

# ---------------------------------------------------------------------------
# Geometry check: the patch set is expected to carry runtime, per-PCI-id
# geometry (same markers driver/build.sh looks for in the patched
# kernel_gsp.c). If a future patch set drops them, the geometry becomes a
# build-time rewrite and must ship as one more patch, per profile.
# ---------------------------------------------------------------------------
GSP_C_REL="src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
MARKER_PATCH="${PATCH_DIR}/sec2-postbl-plm-ss-cfg.patch"
GEOMETRY_PATCH_NEEDED=1
if [[ -f "${MARKER_PATCH}" ]]; then
    missing=0
    for marker in SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID \
                  SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID \
                  0x02779000U 0x02669000U 0x0000001000000000ULL 0x0000000A00000000ULL; do
        grep -qF -- "${marker}" "${MARKER_PATCH}" || missing=1
    done
    (( missing == 0 )) && GEOMETRY_PATCH_NEEDED=0
fi

# ---------------------------------------------------------------------------
# Fetch a pristine reference tree (optional but strongly recommended):
# prefer the exact distfile the ebuild uses, fall back to GitHub.
# ---------------------------------------------------------------------------
REF_TREE=""
REF_SOURCE=""
distdir=""
if command -v portageq &>/dev/null; then
    distdir="$(portageq envvar DISTDIR 2>/dev/null || true)"
fi
# shellcheck disable=SC2086  # DISTDIR is a whitespace-separated path list
dist_tarball=""
for d in ${EXTRA_DISTDIR:-} ${distdir:-/var/cache/distfiles}; do
    if [[ -f "${d}/NVIDIA-kernel-module-source-${VERSION}.tar.xz" ]]; then
        dist_tarball="${d}/NVIDIA-kernel-module-source-${VERSION}.tar.xz"
        break
    fi
done

get_ref_tree() {
    if [[ "${REF_SOURCE}" == "distdir" ]]; then
        mkdir -p "${TMPROOT}/ref"
        tar -xJf "${dist_tarball}" -C "${TMPROOT}/ref"
        [[ -d "${TMPROOT}/ref/NVIDIA-kernel-module-source-${VERSION}" ]] \
            || die "Unexpected layout inside ${dist_tarball}"
        REF_TREE="${TMPROOT}/ref/NVIDIA-kernel-module-source-${VERSION}"
        return
    fi
    [[ "${VERIFY}" != "no" ]] || return
    command -v curl &>/dev/null || { warn "curl not found — cannot fetch GitHub sources"; return; }
    local cached="${BUILD_CACHE_DIR}/open-gpu-kernel-modules-${VERSION}.tar.gz"
    if [[ ! -f "${cached}" ]]; then
        info "Downloading open-gpu-kernel-modules ${VERSION} for verification..."
        mkdir -p "${BUILD_CACHE_DIR}"
        if ! curl -L --fail -sS -o "${cached}.partial" \
            "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VERSION}.tar.gz"; then
            rm -f -- "${cached}.partial"
            warn "Could not download open-gpu-kernel-modules ${VERSION} — skipping verification"
            return
        fi
        mv -- "${cached}.partial" "${cached}"
    fi
    mkdir -p "${TMPROOT}/ref"
    tar -xzf "${cached}" -C "${TMPROOT}/ref"
    local extracted
    extracted="$(find "${TMPROOT}/ref" -maxdepth 1 -type d -name "open-gpu-kernel-modules-*" | head -1)"
    [[ -n "${extracted}" ]] || { warn "GitHub tree not found after extract — skipping verification"; return; }
    REF_TREE="${extracted}"
    REF_SOURCE="github"
}

do_verify() {
    # Apply the original (unprefixed) patches to a pristine tree at repo-root
    # layout — this is exactly what Portage will do, modulo the path prefix.
    local mod="${TMPROOT}/verify/${MODULE_SUBDIR}"
    mkdir -p "${TMPROOT}/verify"
    cp -a "${REF_TREE}" "${mod}"
    local name
    for name in "${PATCH_ORDER[@]}"; do
        if ! patch -p1 -f -g0 -s -d "${mod}" < "$(patch_src "${name}")" >"${TMPROOT}/patch.log" 2>&1; then
            err "Patch ${name} does NOT apply cleanly to the ${REF_SOURCE} reference tree:"
            sed 's/^/    /' "${TMPROOT}/patch.log" >&2
            die "Refusing to install patches that fail verification"
        fi
    done
    ok "All ${#PATCH_ORDER[@]} patches apply cleanly to the ${REF_SOURCE} tree"

    # Faithful runtime-geometry marker check (on the patched tree).
    if [[ -f "${mod}/${GSP_C_REL}" ]] &&
        grep -qF SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID "${mod}/${GSP_C_REL}" &&
        grep -qF SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID "${mod}/${GSP_C_REL}" &&
        grep -qF 0x02779000U "${mod}/${GSP_C_REL}" &&
        grep -qF 0x02669000U "${mod}/${GSP_C_REL}" &&
        grep -qF 0x0000001000000000ULL "${mod}/${GSP_C_REL}" &&
        grep -qF 0x0000000A00000000ULL "${mod}/${GSP_C_REL}"; then
        GEOMETRY_PATCH_NEEDED=0
    else
        GEOMETRY_PATCH_NEEDED=1
    fi

    # Apply the staged, prefixed files exactly as Portage would (-p1 from the
    # tree root, into kernel-module-source/) and require the result to be the
    # same tree as the verified one above.
    local portage_dir="${TMPROOT}/portage"
    mkdir -p "${portage_dir}/${MODULE_SUBDIR}"
    cp -a "${REF_TREE}/." "${portage_dir}/${MODULE_SUBDIR}/"
    local f
    for f in "${STAGED_FILES[@]}"; do
        patch -p1 -f -g0 -s -d "${portage_dir}" < "${STAGE}/${f}" >"${TMPROOT}/dry.log" 2>&1 \
            || { err "Staged ${f} failed to apply in the Portage layout:"; sed 's/^/    /' "${TMPROOT}/dry.log" >&2; die "Refusing to install"; }
    done
    local tree_diff
    tree_diff="$(diff -rq "${mod}" "${portage_dir}/${MODULE_SUBDIR}" 2>&1)" || {
        err "Portage-layout result differs from the verified tree:"
        awk '{print "    " $0}' <<< "${tree_diff}" >&2
        die "Refusing to install"
    }
    ok "Portage-layout application reproduces the verified tree exactly"
}

if [[ "${VERIFY}" != "no" ]]; then
    if [[ "${SOURCE}" == "github" ]]; then
        get_ref_tree
    elif [[ -n "${dist_tarball}" ]]; then
        REF_SOURCE="distdir"
        get_ref_tree
        ok "Verifying against ebuild distfile ${dist_tarball##*/}"
    elif [[ "${SOURCE}" == "distdir" ]]; then
        die "--source=distdir but no NVIDIA-kernel-module-source-${VERSION}.tar.xz in DISTDIR"
    else
        get_ref_tree
    fi
    if [[ -n "${REF_TREE}" ]]; then
        do_verify
    else
        warn "No reference tree available — patches NOT verified"
    fi
fi

# ---------------------------------------------------------------------------
# Build-time geometry (only if the patch set ever loses its runtime path):
# generate one extra patch for the selected profile.
# ---------------------------------------------------------------------------
if (( GEOMETRY_PATCH_NEEDED == 1 )); then
    [[ -n "${REF_TREE}" ]] || die "This patch set needs a build-time geometry rewrite; verification source tree is required to generate it (run with --source=github)"
    [[ "${PROFILE}" == "mixed" ]] && die "Profile 'mixed' needs runtime geometry but this patch set falls back to build-time geometry — pick 8gb or 10gb"
    info "Patch set has no runtime geometry — generating geometry patch for profile ${PROFILE}"

    const_env="$(python3 "${SCRIPT_DIR}/read-constants.py" "${PROJECT_DIR}/common/constants.yaml" "${PATCH_DIR}" "${BUILD_SH}" "${PROFILE}")" \
        || die "common/constants.yaml rejected"
    eval "${const_env}"

    geo_dir="${TMPROOT}/geo"
    mkdir -p "${geo_dir}/a" "${geo_dir}/b"
    cp -a "${REF_TREE}" "${geo_dir}/a/${MODULE_SUBDIR}"
    cp -a "${REF_TREE}" "${geo_dir}/b/${MODULE_SUBDIR}"
    for name in "${PATCH_ORDER[@]}"; do
        patch -p1 -f -g0 -s -d "${geo_dir}/b/${MODULE_SUBDIR}" < "$(patch_src "${name}")" >/dev/null
    done
    python3 - "${geo_dir}/b/${MODULE_SUBDIR}/${GSP_C_REL}" "${CFG1}" "${LMR}" "${FB_BYTES}" "${UNLOCK_LABEL}" <<'PY'
import pathlib, re, sys
path, cfg1, lmr, fb, label = sys.argv[1:6]
text = pathlib.Path(path).read_text()
text2, n1 = re.subn(r"(NvU32 cfg1Value = )0x[0-9A-Fa-f]+(U;)", rf"\g<1>{cfg1}\g<2>", text, count=1)
text2, n2 = re.subn(r"(NvU32 lmrValue\s*=\s*)0x[0-9A-Fa-f]+(U;)", rf"\g<1>{lmr}\g<2>", text2, count=1)
text2, n3 = re.subn(r"(NvU64 targetFbBytes = )0x[0-9A-Fa-f]+ULL;\s*/\*[^*]*\*/", rf"\g<1>{fb}ULL;  /* {label} */", text2, count=1)
if n1 != 1 or n2 != 1 or n3 != 1:
    raise SystemExit(f"geometry rewrite failed (cfg1={n1} lmr={n2} fb={n3}); check kernel_gsp.c markers")
pathlib.Path(path).write_text(text2)
PY
    # diff exits 1 when files differ, which is success here.
    ( cd "${geo_dir}" && { diff -ruN a b > "${STAGE}/15-geometry-${PROFILE}.patch" || [[ $? -eq 1 ]]; } )
    STAGED_FILES+=("15-geometry-${PROFILE}.patch")
    ok "Generated 15-geometry-${PROFILE}.patch"
else
    info "Runtime geometry by PCI device id: one patch set covers 8gb, 10gb and mixed"
fi

# ---------------------------------------------------------------------------
# Warn about stale cmpunlocker modules shadowing the ebuild's own modules.
# ---------------------------------------------------------------------------
# Only nvidia*.ko in that dir shadow the ebuild modules; cmp_no_bus_reset.ko
# (VM passthrough helper) coexists with them fine.
for d in /lib/modules/*/updates/cmpunlocker; do
    [[ -e "${d}" ]] || continue
    shadow=""
    for k in nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko nvidia-peermem.ko; do
        [[ -e "${d}/${k}" ]] && shadow="yes"
    done
    [[ -z "${shadow}" ]] && continue
    warn "Stale cmpunlocker NVIDIA modules found in ${d}"
    warn "They can shadow the ebuild-built modules — remove them (sudo ${PROJECT_DIR}/remove.sh --yes) before emerging"
done

# ---------------------------------------------------------------------------
# Install.
# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
    echo ""
    info "[dry-run] would install to ${DEST}/:"
    for f in "${STAGED_FILES[@]}"; do
        printf '        %s\n' "${f}"
    done
    info "[dry-run] manifest ${DEST}/${MANIFEST_NAME} would list these files"
    exit 0
fi

write_target="${DEST}"
[[ -e "${write_target}" ]] || write_target="$(dirname "${DEST}")"
[[ -w "${write_target}" ]] || die "Cannot write to ${DEST} — run as root (or use --dry-run / --dest=)"

mkdir -p "${DEST}"
# Replace files from a previous run first.
if [[ -f "${DEST}/${MANIFEST_NAME}" ]]; then
    mapfile -t old < <(grep -v '^[[:space:]]*$' "${DEST}/${MANIFEST_NAME}")
    for f in "${old[@]}"; do
        rm -f -- "${DEST}/${f}"
    done
fi
for f in "${STAGED_FILES[@]}"; do
    install -m 0644 "${STAGE}/${f}" "${DEST}/${f}"
done
printf '%s\n' "${STAGED_FILES[@]}" > "${DEST}/${MANIFEST_NAME}"
chmod 0644 "${DEST}/${MANIFEST_NAME}"
ok "Installed ${#STAGED_FILES[@]} file(s) into ${DEST}"

echo ""
info "Next steps:"
echo "  1. Make sure the version is installable, e.g.:"
echo "       echo \"=${CATEGORY}/${PN}-${VERSION}\" >> /etc/portage/package.accept_keywords"
echo "  2. Build with the patches:"
echo "       sudo emerge -1v =${CATEGORY}/${PN}-${VERSION}"
echo "     The build log must show: Applying user patches from /etc/portage/patches ..."
echo "  3. System configuration (modprobe.d Gen2 option, gen2.service,"
echo "     passthrough, IOMMU kernel parameters) is not done by Portage —"
echo "     see docs/GENTOO.md."
echo "  4. Cold reboot, then verify: nvidia-smi, sudo dmesg | grep SEC2_DEBUG"
echo ""
info "Kernel upgrades then need no cmpunlocker run: emerge @module-rebuild"
info "(or USE=dist-kernel with a distribution kernel) re-applies the patches."
