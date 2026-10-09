#!/usr/bin/env bash
set -Eeuo pipefail

# Adapted from rjohny55/cmp170hx-unlocker, 2026-10-09.

log() { printf '[cmp170-gen2] %s\n' "$*" | tee -a /var/log/gen2.log; }
die() { log "ERROR: $*" >&2; exit 1; }
readreg() {
    local value
    value=$(setpci -s "$1" "$2") || return 1
    [[ $value =~ ^[[:xdigit:]]{4}([[:xdigit:]]{4})?$ &&
       ${value,,} != ffff && ${value,,} != ffffffff ]] || return 1
    printf '%s\n' "$value"
}
second_pass_started=0
declare -a restore_modules=()

restore_driver() {
    if [[ ${second_pass_started} -eq 1 ]]; then
        modprobe nvidia || true
        for module in "${restore_modules[@]}"; do modprobe "$module" || true; done
    fi
}
trap restore_driver EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

[[ ${EUID} -eq 0 ]] || die 'run as root'
[[ $# -le 1 && ( ${1:-auto} == auto || ${1:-auto} =~ ^[1-9][0-9]*$ ) ]] || die 'usage: sudo bash tools/gen2-second-pass.sh [EXPECTED_GPU_COUNT|auto]'
expected_count=${1:-auto}
for tool in setpci nvidia-smi modprobe fuser flock; do
    command -v "$tool" >/dev/null || die "$tool is required"
done
exec 9>/run/cmp170-gen2-second-pass.lock
flock -n 9 || die 'another Gen2 activation or service installation is in progress'

declare -a gpus=()
declare -A ports=()
for path in /sys/bus/pci/devices/*; do
    [[ -f ${path}/vendor && -f ${path}/device ]] || continue
    [[ $(<"${path}/vendor") == 0x10de ]] || continue
    case $(<"${path}/device") in
        0x20c2|0x2082) ;;
        *) continue ;;
    esac
    gpu=${path##*/}
    port=$(basename "$(dirname "$(readlink -f "$path")")")
    [[ -r /sys/bus/pci/devices/${port}/class ]] || die "no upstream port for $gpu"
    [[ $(<"/sys/bus/pci/devices/${port}/class") == 0x0604* ]] || die "$port is not a PCI bridge"
    gpus+=("$gpu")
    ports["$gpu"]=$port
done
if [[ $expected_count == auto ]]; then
    expected_count=${#gpus[@]}
    [[ $expected_count -gt 0 ]] || die 'no supported CMP 170HX cards detected; nothing to activate'
    log "automatic inventory: $expected_count CMP 170HX card(s) detected"
fi
[[ ${#gpus[@]} -eq ${expected_count} ]] || die "detected ${#gpus[@]} CMP 170HX, expected $expected_count; check PCIe enumeration"

# Do not reset a card with active CUDA clients or another device-file user.
check_idle() {
    local result
    if fuser /dev/nvidia* >/dev/null 2>&1; then
        die 'NVIDIA device files are in use; stop GPU workloads before retrying'
    else
        result=$?
        [[ $result -eq 1 ]] || die "fuser failed (status $result); refusing driver reset"
    fi
}
check_idle

link_gen() {
    local status
    status=$(readreg "$1" CAP_EXP+12.w) || return 1
    [[ $((16#$status & 15)) -gt 0 && $((16#$status & 15)) -le 6 ]] || return 1
    printf '%d\n' "$((16#$status & 15))"
}

show_link() {
    local gpu=$1 port=${ports[$1]}
    log "$gpu GPU cap=$(readreg "$gpu" CAP_EXP+0c.l) target=$(readreg "$gpu" CAP_EXP+30.w) status=$(readreg "$gpu" CAP_EXP+12.w); port $port cap=$(readreg "$port" CAP_EXP+0c.l) target=$(readreg "$port" CAP_EXP+30.w) status=$(readreg "$port" CAP_EXP+12.w)"
}

retrain() {
    local gpu=$1 port=${ports[$1]} pass i gpu_target port_target gpu_gen port_gen
    gpu_gen=$(link_gen "$gpu") || die "cannot read link status for $gpu"
    port_gen=$(link_gen "$port") || die "cannot read link status for $port"
    [[ $gpu_gen -ge 2 && $port_gen -ge 2 ]] && return 0

    for pass in 1 2; do
        [[ -e /sys/bus/pci/devices/$gpu ]] || die "$gpu disappeared"
        # Mask only Target Link Speed. Width is negotiated by the physical
        # link/BIOS; this procedure is identical for x4, x8 and x16.
        setpci -s "$gpu" CAP_EXP+30.w=0002:000f || die "target-speed write failed for $gpu"
        setpci -s "$port" CAP_EXP+30.w=0002:000f || die "target-speed write failed for $port"
        gpu_target=$(readreg "$gpu" CAP_EXP+30.w) || die "target-speed read failed for $gpu"
        port_target=$(readreg "$port" CAP_EXP+30.w) || die "target-speed read failed for $port"
        gpu_target=$((16#$gpu_target & 15))
        port_target=$((16#$port_target & 15))
        if [[ $gpu_target -ne 2 || $port_target -ne 2 ]]; then
            log "$gpu target-speed readback GPU=$gpu_target port=$port_target; retrain cannot reach Gen2 yet"
            return 1
        fi

        # Preserve ASPM and every other Link Control bit; set Retrain only.
        setpci -s "$gpu" CAP_EXP+10.w=0020:0020 || die "retrain write failed for $gpu"
        sleep 0.05
        setpci -s "$port" CAP_EXP+10.w=0020:0020 || die "retrain write failed for $port"
        for ((i=1; i<=200; i++)); do
            [[ -e /sys/bus/pci/devices/$gpu ]] || die "$gpu disappeared during retrain"
            gpu_gen=$(link_gen "$gpu") || die "cannot read link status for $gpu"
            port_gen=$(link_gen "$port") || die "cannot read link status for $port"
            if [[ $gpu_gen -ge 2 && $port_gen -ge 2 ]]; then
                log "$gpu reached Gen2 on pass $pass, poll $i"
                show_link "$gpu"
                return 0
            fi
            sleep 0.01
        done
        log "$gpu remained Gen$(link_gen "$gpu") after pass $pass"
        sleep 0.5
    done
    return 1
}

modprobe nvidia
nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader || die 'driver first pass failed'
for gpu in "${gpus[@]}"; do show_link "$gpu"; done

first_pass_ok=1
for gpu in "${gpus[@]}"; do
    retrain "$gpu" || first_pass_ok=0
done
if [[ $first_pass_ok -eq 1 ]]; then
    log 'all detected cards reached Gen2 on first pass'
else
    for gpu in "${gpus[@]}"; do
        [[ -w /sys/bus/pci/devices/${gpu}/reset ]] || die "FLR unavailable for $gpu"
        [[ $(basename "$(readlink -f "/sys/bus/pci/devices/${gpu}/driver")") == nvidia ]] || die "$gpu is not bound to nvidia"
    done
    check_idle
    declare -a unload_modules=()
    for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem; do
        if grep -q "^$module " /proc/modules; then
            unload_modules+=("$module")
            restore_modules=("$module" "${restore_modules[@]}")
        fi
    done
    log 'starting FLR and second driver pass'
    second_pass_started=1
    for gpu in "${gpus[@]}"; do
        printf '%s\n' "$gpu" > "/sys/bus/pci/devices/${gpu}/driver/unbind"
    done
    modprobe -r "${unload_modules[@]}" nvidia
    grep -q '^nvidia ' /proc/modules && die 'nvidia module is still loaded'
    for gpu in "${gpus[@]}"; do
        printf '1\n' > "/sys/bus/pci/devices/${gpu}/reset"
    done
    modprobe nvidia
    # nvidia-smi initializes the driver; nvidia-modprobe is not installed on
    # the validated host and is not required for this sequence.
    nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader || die 'driver second pass failed'
    for gpu in "${gpus[@]}"; do
        show_link "$gpu"
        retrain "$gpu" || die "$gpu remained below Gen2 after second pass"
    done
fi

sleep 2
for gpu in "${gpus[@]}"; do
    [[ $(link_gen "$gpu") -ge 2 ]] || die "$gpu dropped below Gen2 during stability check"
    [[ $(link_gen "${ports[$gpu]}") -ge 2 ]] || die "upstream port for $gpu dropped below Gen2"
done
nvidia-smi --query-gpu=uuid,pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader
log "PASS: ${#gpus[@]} detected CMP 170HX cards are at Gen2 or better"
