#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly driver_version="610.43.03"
readonly expected_source_sha256="7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc"
readonly kernel_release="${KERNEL_RELEASE:-$(uname -r)}"
readonly jobs="${JOBS:-4}"
readonly work_root="${CMP90_STOCKFLOW_WORK_ROOT:-${script_dir}/work}"
readonly variant="${CMP90_STOCKFLOW_VARIANT:-probe0}"
readonly low_mem_g_bindata="${CMP90_STOCKFLOW_LOW_MEM_G_BINDATA:-1}"
artifact_suffix="${variant}"
secondary_patch_file=""
tertiary_patch_file=""
case "${variant}" in
    probe0)
        readonly default_patch_file="${script_dir}/patches/0001-6104303-cmp90hx-stockflow-probe0-after-gfw-v67.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_PROBE0_BUILD"
        readonly required_variant_marker="intentional stop before GSP-RM continuation"
        ;;
    rejoin1)
        readonly default_patch_file="${script_dir}/patches/0002-6104303-cmp90hx-stockflow-rejoin1-after-gfw-v67.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN1_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN1"
        ;;
    rejoin2)
        readonly default_patch_file="${script_dir}/patches/0003-6104303-cmp90hx-stockflow-rejoin2-wpr2-gate.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN2_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN2"
        ;;
    rejoin3)
        readonly default_patch_file="${script_dir}/patches/0004-6104303-cmp90hx-stockflow-rejoin3-scrubber-skip.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN3_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN3"
        ;;
    rejoin4)
        readonly default_patch_file="${script_dir}/patches/0005-6104303-cmp90hx-stockflow-rejoin4-fwsec-diag.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN4_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN4"
        ;;
    rejoin5)
        readonly default_patch_file="${script_dir}/patches/0006-6104303-cmp90hx-stockflow-rejoin5-two-stage-booter.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN5_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN5"
        ;;
    rejoin6)
        readonly default_patch_file="${script_dir}/patches/0007-6104303-cmp90hx-stockflow-rejoin6-restore-stock-continue.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN6_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN6"
        ;;
    rejoin7)
        readonly default_patch_file="${script_dir}/patches/0008-6104303-cmp90hx-stockflow-rejoin7-unload-retry.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN7_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN7"
        ;;
    rejoin8)
        readonly default_patch_file="${script_dir}/patches/0009-6104303-cmp90hx-stockflow-rejoin8-clear-wpr2-retry.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN8_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN8"
        ;;
    rejoin9)
        readonly default_patch_file="${script_dir}/patches/0010-6104303-cmp90hx-stockflow-rejoin9-early-plm-handoff.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN9_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN9"
        ;;
    postinit1)
        readonly default_patch_file="${script_dir}/patches/0011-6104303-cmp90hx-stockflow-postinit1-after-gsp-ready.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_POSTINIT1_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_POSTINIT1"
        ;;
    rejoin12)
        readonly default_patch_file="${script_dir}/patches/0012-6104303-cmp90hx-stockflow-rejoin12-official-flr.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN12_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN12"
        artifact_suffix="rejoin12-official-flr"
        ;;
    rejoin13)
        readonly default_patch_file="${script_dir}/patches/0013-6104303-cmp90hx-stockflow-rejoin13-open-retry.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN13_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN13"
        artifact_suffix="rejoin13-open-retry"
        ;;
    rejoin14)
        readonly default_patch_file="${script_dir}/patches/0014-6104303-cmp90hx-stockflow-rejoin14-multigpu-state.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN14_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN14"
        artifact_suffix="rejoin14-multigpu-state"
        ;;
    rejoin15)
        readonly default_patch_file="${script_dir}/patches/0014-6104303-cmp90hx-stockflow-rejoin14-multigpu-state.patch"
        secondary_patch_file="${script_dir}/patches/0015-6104303-cmp90hx-stockflow-rejoin15-serialized-start.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN15_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN15"
        artifact_suffix="rejoin15-serialized-start"
        ;;
    rejoin16)
        readonly default_patch_file="${script_dir}/patches/0014-6104303-cmp90hx-stockflow-rejoin14-multigpu-state.patch"
        secondary_patch_file="${script_dir}/patches/0015-6104303-cmp90hx-stockflow-rejoin15-serialized-start.patch"
        tertiary_patch_file="${script_dir}/patches/0016-6104303-cmp90hx-stockflow-rejoin16-pcie-jtag-plm.patch"
        readonly pass_label="PASS_CMP90HX_6104303_STOCKFLOW_REJOIN16_BUILD"
        readonly required_variant_marker="CMP90_STOCKFLOW_REJOIN16"
        artifact_suffix="rejoin16-pcie-jtag-plm"
        ;;
    *)
        printf 'unsupported CMP90_STOCKFLOW_VARIANT: %s\n' "${variant}" >&2
        exit 2
        ;;
esac
readonly artifact_suffix
readonly secondary_patch_file
readonly tertiary_patch_file
readonly source_dir="${work_root}/NVIDIA-kernel-module-source-${driver_version}-${variant}"
readonly artifact_dir="${script_dir}/artifacts/${driver_version}-${kernel_release}-${artifact_suffix}"
readonly patch_file="${CMP90_STOCKFLOW_PATCH:-${default_patch_file}}"

source_tarball="${CMP90_SOURCE_TARBALL:-}"
source_dir_input="${CMP90_SOURCE_DIR:-}"

usage() {
    printf '%s\n' \
        "usage: ./build-candidate.sh [--source-tarball FILE | --source-dir DIR]" \
        "" \
        "Builds the CMP 90HX 610.43.03 stockflow artifact for the" \
        "running kernel. This is a build-only helper: it does not install," \
        "load, unload, or persist NVIDIA modules." \
        "" \
        "Set CMP90_STOCKFLOW_LOW_MEM_G_BINDATA=0 to keep NVIDIA's default" \
        "generated/g_bindata.c optimization. Default: 1, compile that one" \
        "large generated object with -O0 to reduce build memory pressure." \
        "" \
        "Set CMP90_STOCKFLOW_VARIANT=probe0, rejoin1, rejoin2, rejoin3, rejoin4, rejoin5, rejoin6, rejoin7, rejoin8, rejoin9, postinit1, rejoin12, rejoin13, rejoin14, rejoin15, or rejoin16. Default: probe0." >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-tarball)
            source_tarball="${2:?--source-tarball requires a file}"
            shift 2
            ;;
        --source-dir)
            source_dir_input="${2:?--source-dir requires a directory}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -n "${source_tarball}" && -n "${source_dir_input}" ]]; then
    printf 'choose only one of --source-tarball or --source-dir\n' >&2
    exit 2
fi
if [[ -z "${source_tarball}" && -z "${source_dir_input}" ]]; then
    printf 'provide --source-tarball or --source-dir; this experiment does not auto-download sources\n' >&2
    exit 2
fi
case "${low_mem_g_bindata}" in
    0|1) ;;
    *)
        printf 'CMP90_STOCKFLOW_LOW_MEM_G_BINDATA must be 0 or 1, got: %s\n' \
            "${low_mem_g_bindata}" >&2
        exit 2
        ;;
esac

for command in awk cp find grep install make mkdir modinfo mv patch sha256sum sort strings tar; do
    command -v "${command}" >/dev/null
done
[[ -d "/lib/modules/${kernel_release}/build" ]]
[[ -f "${patch_file}" ]]

if [[ -e "${source_dir}" ]]; then
    printf 'Refusing to reuse existing source directory: %s\n' "${source_dir}" >&2
    printf 'Move it aside and run this script again.\n' >&2
    exit 10
fi

mkdir -p "${work_root}" "${artifact_dir}"
if [[ -n "${source_dir_input}" ]]; then
    [[ -d "${source_dir_input}" ]]
    cp -a "${source_dir_input}" "${source_dir}"
else
    [[ -f "${source_tarball}" ]]
    actual_source_sha256="$(sha256sum "${source_tarball}" | awk '{print $1}')"
    if [[ "${actual_source_sha256}" != "${expected_source_sha256}" ]]; then
        printf 'source tarball SHA-256 mismatch: expected %s got %s\n' \
            "${expected_source_sha256}" "${actual_source_sha256}" >&2
        exit 11
    fi
    extract_dir="${work_root}/extract-${driver_version}-${variant}"
    if [[ -e "${extract_dir}" ]]; then
        printf 'Refusing to reuse existing extract directory: %s\n' "${extract_dir}" >&2
        printf 'Move it aside and run this script again.\n' >&2
        exit 12
    fi
    mkdir -p "${extract_dir}"
    tar -xf "${source_tarball}" -C "${extract_dir}"
    mapfile -t extracted_entries < <(find "${extract_dir}" -mindepth 1 -maxdepth 1 | sort)
    mapfile -t extracted_roots < <(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
    if [[ "${#extracted_entries[@]}" -eq 1 && "${#extracted_roots[@]}" -eq 1 ]]; then
        mv "${extracted_roots[0]}" "${source_dir}"
    else
        mv "${extract_dir}" "${source_dir}"
    fi
fi

patch --dry-run -d "${source_dir}" -p1 < "${patch_file}" >/dev/null
patch -d "${source_dir}" -p1 < "${patch_file}" >/dev/null
if [[ -n "${secondary_patch_file}" ]]; then
    patch --dry-run -d "${source_dir}" -p1 < "${secondary_patch_file}" >/dev/null
    patch -d "${source_dir}" -p1 < "${secondary_patch_file}" >/dev/null
fi
if [[ -n "${tertiary_patch_file}" ]]; then
    patch --dry-run -d "${source_dir}" -p1 < "${tertiary_patch_file}" >/dev/null
    patch -d "${source_dir}" -p1 < "${tertiary_patch_file}" >/dev/null
fi

if [[ "${low_mem_g_bindata}" == "1" ]]; then
    nvidia_makefile="${source_dir}/src/nvidia/Makefile"
    grep -qF "CMP90_LOW_MEM_G_BINDATA" "${nvidia_makefile}" || {
        printf '\n# CMP90_LOW_MEM_G_BINDATA: compile huge firmware bindata at O0 on low-memory rigs.\n' >> "${nvidia_makefile}"
        printf '$(call BUILD_OBJECT_LIST,generated/g_bindata.c): CFLAGS := $(filter-out -O2,$(CFLAGS)) -O0\n' >> "${nvidia_makefile}"
    }
fi

make -C "${source_dir}" modules -j"${jobs}" KERNEL_UNAME="${kernel_release}"

for module in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
    if [[ -f "${source_dir}/kernel-open/${module}.ko" ]]; then
        install -m 0644 "${source_dir}/kernel-open/${module}.ko" \
            "${artifact_dir}/${module}.ko"
    fi
done

[[ -f "${artifact_dir}/nvidia.ko" ]]
[[ "$(modinfo -F version "${artifact_dir}/nvidia.ko")" == "${driver_version}" ]]
[[ "$(modinfo -F vermagic "${artifact_dir}/nvidia.ko" | awk '{print $1}')" == \
    "${kernel_release}" ]]
if [[ "${variant}" != "postinit1" ]]; then
    grep -a -q 'CMP90_PROD_STACK_SHIFT_PLM_V67: native GA102 status=' \
        "${artifact_dir}/nvidia.ko"
fi
grep -a -q "${required_variant_marker}" "${artifact_dir}/nvidia.ko"

(cd "${artifact_dir}" && sha256sum ./*.ko > checksums.sha256)
printf '%s\n%s\n' "${pass_label}" "${artifact_dir}"
