#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

LIB="/usr/local/lib/cmpunlocker/vgpu"
CONF="/etc/modprobe.d/cmpunlocker-vgpu.conf"
UNITS="/etc/systemd/system"
VGPU_XML="/usr/share/nvidia/vgpu/vgpuConfig.xml"

usage() {
    cat <<'EOF'
Usage: sudo tools/vgpu.sh install <NVIDIA-Linux-x86_64-<ver>-vgpu-kvm.run>
       sudo tools/vgpu.sh enable <BDF>
       sudo tools/vgpu.sh unhide <BDF>
       sudo tools/vgpu.sh start <BDF> [VFs]
       sudo tools/vgpu.sh stop <BDF>

  install  install the vGPU manager userspace and services from the package
  enable   run this card in SR-IOV host mode from the next nvidia load
  unhide   expose SR-IOV, MSI-X and a 4 GB BAR1 on this card (once per boot)
  start    create VFs (default 4) and start vgpud and vgpu-mgr
  stop     stop the services and remove the VFs; power off the VMs first
EOF
}

ecam() {
    python3 - "$@" <<'PY'
import mmap
import os
import struct
import sys

op, bdf, off = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
base = struct.unpack_from("<Q", open("/sys/firmware/acpi/tables/MCFG", "rb").read(), 44)[0]
bus, rest = bdf.split(":")[-2:]
dev, fn = rest.split(".")
addr = base + (int(bus, 16) << 20) + (int(dev, 16) << 15) + (int(fn, 16) << 12) + off
write = op == "write"
fd = os.open("/dev/mem", (os.O_RDWR | os.O_SYNC) if write else os.O_RDONLY)
mem = mmap.mmap(fd, mmap.PAGESIZE, mmap.MAP_SHARED,
                mmap.PROT_READ | (mmap.PROT_WRITE if write else 0), offset=addr & ~0xfff)
pos = addr & 0xfff
if write:
    mem[pos:pos + 4] = int(sys.argv[4], 16).to_bytes(4, "little")
print("0x%08x" % int.from_bytes(mem[pos:pos + 4], "little"))
PY
}

do_unhide() {
    local gpu="$1" port nic v
    [[ -e "/sys/bus/pci/devices/${gpu}" ]] || die "${gpu} not present"
    grep -qw "iomem=relaxed" /proc/cmdline || die "iomem=relaxed missing from the kernel command line"
    grep -qE "pci=[^ ]*realloc" /proc/cmdline || die "pci=realloc=on missing from the kernel command line"
    v="$(setpci -s "${gpu}" 71c.l)"
    if (( (0x${v} & 1) == 0 )); then
        ok "${gpu} already exposes SR-IOV"
        return 0
    fi
    port="$(readlink -f "/sys/bus/pci/devices/${gpu}" | cut -d/ -f5)"
    nic="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || true)"
    if [[ -n "${nic}" && "$(readlink -f "/sys/class/net/${nic}")" == *"/${port}/"* ]]; then
        die "the default-route NIC sits behind ${port}"
    fi
    systemctl stop nvidia-persistenced 2>/dev/null || true
    modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia_vgpu_vfio nvidia 2>/dev/null || true
    grep -q '^nvidia ' /proc/modules && die "could not unload nvidia"
    find "$(readlink -f "/sys/bus/pci/devices/${port}")" \
        -regex '.*/[0-9a-f]\{4\}:[0-9a-f]\{2\}:[0-9a-f]\{2\}\.[0-7]/power/control' \
        -exec sh -c 'echo on > "$1"' _ {} \;
    sleep 1
    echo 0 > /sys/bus/pci/drivers_autoprobe
    echo 1 > "/sys/bus/pci/devices/${port}/remove"
    sleep 3
    v="$(ecam read "${gpu}" 71c)"
    if [[ "${v}" == 0xffffffff ]]; then
        echo 1 > /sys/bus/pci/rescan
        echo 1 > /sys/bus/pci/drivers_autoprobe
        die "${gpu} unreachable over ECAM"
    fi
    ecam write "${gpu}" 71c "$(printf %08x $(( v & ~1 )))" >/dev/null
    v="$(ecam read "${gpu}" 41c)"
    ecam write "${gpu}" 41c "$(printf %08x $(( (v & ~(1 << 29)) | (1 << 17) )))" >/dev/null
    ecam write "${gpu}" 724 00000030 >/dev/null
    ecam write "${gpu}" dcc 8000000a >/dev/null
    v="$(ecam read "${gpu}" bc0)"
    ecam write "${gpu}" bc0 "$(printf %08x $(( (v & ~0x3f00) | (12 << 8) )))" >/dev/null
    echo 1 > /sys/bus/pci/rescan
    sleep 8
    echo 1 > /sys/bus/pci/drivers_autoprobe
    for v in /sys/bus/pci/devices/*; do
        [[ "$(readlink -f "${v}")" == *"/${port}/"* && -e "${v}/vendor" ]] || continue
        basename "${v}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    done
    [[ -e "/sys/bus/pci/devices/${gpu}/sriov_totalvfs" ]] || die "${gpu} did not expose SR-IOV"
    ok "${gpu}: $(cat "/sys/bus/pci/devices/${gpu}/sriov_totalvfs") VFs, BAR1 $(( ($(sed -n 2p "/sys/bus/pci/devices/${gpu}/resource" | awk '{print $2 " - " $1}') + 1) >> 20 )) MB"
}

plugin_dir() {
    local ml
    ml="$(ldconfig -p | awk '/libnvidia-ml\.so\.1 .*x86-64/ {print $NF; exit}')"
    [[ -n "${ml}" ]] || die "libnvidia-ml.so.1 not found; install nvidia-open first"
    dirname "${ml}"
}

do_install() {
    local run="$1" ver dir tmp lib
    ver="$(basename "${run}" | sed -n 's/^NVIDIA-Linux-x86_64-\([0-9.]*\)-vgpu-kvm\.run$/\1/p')"
    [[ -f "${run}" && -n "${ver}" ]] || die "not an NVIDIA vGPU KVM host package: ${run}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    (cd "${tmp}" && sh "${run}" --extract-only >/dev/null)
    dir="${tmp}/NVIDIA-Linux-x86_64-${ver}-vgpu-kvm"

    mkdir -p "${LIB}"
    install -m 0755 "${dir}/nvidia-vgpud" "${dir}/nvidia-vgpu-mgr" "${LIB}/"
    for lib in libnvidia-vgpu libnvidia-vgxcfg libnvidia-ml; do
        install -m 0644 "${dir}/${lib}.so.${ver}" "${LIB}/"
        ln -sf "${lib}.so.${ver}" "${LIB}/${lib}.so.1"
    done
    ln -sf "${LIB}/libnvidia-vgpu.so.${ver}" "$(plugin_dir)/libnvidia-vgpu.so"
    ok "Installed vGPU ${ver} userspace in ${LIB}"

    mkdir -p "$(dirname "${VGPU_XML}")"
    python3 "${SCRIPT_DIR}/vgpu-config.py" "${dir}/vgpuConfig.xml" "${VGPU_XML}"

    cat > "${UNITS}/cmpunlocker-vgpud.service" <<EOF
[Unit]
Description=cmpunlocker: NVIDIA vGPU daemon

[Service]
Type=oneshot
Environment=LD_LIBRARY_PATH=${LIB}
ExecStart=${LIB}/nvidia-vgpud
EOF
    cat > "${UNITS}/cmpunlocker-vgpu-mgr.service" <<EOF
[Unit]
Description=cmpunlocker: NVIDIA vGPU manager
Requires=cmpunlocker-vgpud.service
After=cmpunlocker-vgpud.service

[Service]
Type=forking
KillMode=process
Environment=LD_LIBRARY_PATH=${LIB}
ExecStart=${LIB}/nvidia-vgpu-mgr
ExecStopPost=/bin/rm -rf /var/run/nvidia-vgpu-mgr
EOF
    systemctl daemon-reload
    [[ -f "${CONF}" ]] || printf 'options nvidia NVreg_RegistryDwords="RMSetSriovMode=0"\n' > "${CONF}"
    ok "Wrote services and ${CONF}"
}

do_enable() {
    local bdf="$1" devs
    [[ -e "/sys/bus/pci/devices/${bdf}" ]] || die "${bdf} not present"
    devs="$(sed -n 's/.*NVreg_RegistryDwordsPerDevice="\(.*\)"/\1/p' "${CONF}" 2>/dev/null || true)"
    [[ "${devs}" == *"pci=${bdf};"* ]] || devs="${devs}pci=${bdf};RMSetSriovMode=1;"
    printf 'options nvidia NVreg_RegistryDwords="RMSetSriovMode=0" NVreg_RegistryDwordsPerDevice="%s"\n' \
        "${devs}" > "${CONF}"
    ok "${bdf} runs in SR-IOV host mode from the next nvidia load (${CONF})"
}

set_numvfs() {
    local pf="$1" count="$2" dev="/sys/bus/pci/devices/$1"
    nvidia-smi -pm 0 >/dev/null
    echo 1 > "/proc/driver/nvidia/gpus/${pf}/unbindLock"
    echo "${pf}" > /sys/bus/pci/drivers/nvidia/unbind
    modprobe pci-pf-stub
    echo pci-pf-stub > "${dev}/driver_override"
    echo "${pf}" > /sys/bus/pci/drivers/pci-pf-stub/bind
    echo 0 > "${dev}/sriov_drivers_autoprobe"
    echo "${count}" > "${dev}/sriov_numvfs"
    echo "${pf}" > /sys/bus/pci/drivers/pci-pf-stub/unbind
    echo > "${dev}/driver_override"
    echo "${pf}" > /sys/bus/pci/drivers/nvidia/bind
    nvidia-smi -pm 1 >/dev/null
}

do_start() {
    local pf="$1" count="${2:-4}" vf dev="/sys/bus/pci/devices/$1"
    [[ -e "${dev}/sriov_totalvfs" ]] || die "${pf} has no SR-IOV capability; run tools/vgpu.sh unhide ${pf}"
    [[ "$(cat "${dev}/sriov_numvfs")" -eq 0 ]] || die "${pf} already has VFs"
    modprobe nvidia-vgpu-vfio
    set_numvfs "${pf}" "${count}"
    for vf in "${dev}"/virtfn*; do
        vf="$(basename "$(readlink -f "${vf}")")"
        echo | tee "/sys/bus/pci/devices/${vf}/reset_method" >/dev/null
        echo nvidia > "/sys/bus/pci/devices/${vf}/driver_override"
        echo "${vf}" > /sys/bus/pci/drivers/nvidia/bind
    done
    systemctl start cmpunlocker-vgpud.service cmpunlocker-vgpu-mgr.service
    vf="$(basename "$(readlink -f "${dev}/virtfn0")")"
    ok "${count} VFs on ${pf}; creatable on ${vf}:"
    cat "/sys/bus/pci/devices/${vf}/nvidia/creatable_vgpu_types" 2>/dev/null || warn "no creatable vGPU types"
}

do_stop() {
    local pf="$1" vf dev="/sys/bus/pci/devices/$1"
    pgrep -x qemu-system-x86 >/dev/null && die "QEMU is running; power the VMs off first"
    systemctl stop cmpunlocker-vgpu-mgr.service cmpunlocker-vgpud.service
    for vf in "${dev}"/virtfn*; do
        [[ -e "${vf}" ]] || continue
        vf="$(basename "$(readlink -f "${vf}")")"
        echo 0 > "/sys/bus/pci/devices/${vf}/nvidia/current_vgpu_type" 2>/dev/null || true
        [[ -e "/sys/bus/pci/drivers/nvidia/${vf}" ]] && echo "${vf}" > /sys/bus/pci/drivers/nvidia/unbind
    done
    set_numvfs "${pf}" 0
    echo 1 > "${dev}/sriov_drivers_autoprobe"
    ok "vGPU stopped on ${pf}"
}

[[ "${EUID}" -eq 0 ]] || die "Run as root"
case "${1:-}" in
    install) [[ $# -eq 2 ]] || { usage; exit 1; }; do_install "$2" ;;
    enable)  [[ $# -eq 2 ]] || { usage; exit 1; }; do_enable "$2" ;;
    unhide)  [[ $# -eq 2 ]] || { usage; exit 1; }; do_unhide "$2" ;;
    start)   [[ $# -ge 2 ]] || { usage; exit 1; }; do_start "$2" "${3:-4}" ;;
    stop)    [[ $# -eq 2 ]] || { usage; exit 1; }; do_stop "$2" ;;
    *) usage; exit 1 ;;
esac
