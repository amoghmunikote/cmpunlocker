#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

KVER="${CMPUNLOCKER_KVER:-$(uname -r)}"
STATE_DIR="/var/lib/cmpunlocker"
SHIM_MOK_DIR="/var/lib/shim-signed/mok"
MOK_KEY=""
MOK_CERT=""
SIGN_TOOL=""

usage() {
    cat <<'EOF'
Usage: sudo ./tools/sign-modules.sh prepare
       sudo ./tools/sign-modules.sh sign <module.ko>...

prepare  pick (or create) the Machine Owner Key the modules will be signed
         with and, when Secure Boot is on, ask shim to enroll it on the
         next boot
sign     sign the given modules with that key; modules that already carry
         a signature are left alone

Only Ubuntu is supported for now. The key is the one Ubuntu's DKMS uses:
CMPUNLOCKER_MOK_KEY/CMPUNLOCKER_MOK_CERT if set, else mok_signing_key/
mok_certificate from /etc/dkms/framework.conf, else /var/lib/shim-signed/mok
(created with update-secureboot-policy --new-key when missing).
EOF
}

secure_boot_enabled() {
    local var
    if command -v mokutil &>/dev/null; then
        [[ "$(mokutil --sb-state 2>/dev/null || true)" == *"SecureBoot enabled"* ]]
        return
    fi
    var="$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1 || true)"
    [[ -n "${var}" ]] || return 1
    [[ "$(od -An -tu1 -j4 -N1 "${var}" 2>/dev/null | tr -d ' ')" == "1" ]]
}

ubuntu_host() {
    [[ -r /etc/os-release ]] || return 1
    [[ "$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')" == "ubuntu" ]]
}

require_ubuntu() {
    ubuntu_host && return 0
    if secure_boot_enabled; then
        die "Secure Boot is enabled. Disable it before installing unsigned patched modules (module signing is only supported on Ubuntu for now)"
    fi
    info "Module signing is only supported on Ubuntu for now; modules are left unsigned"
    exit 0
}

dkms_conf_value() {
    local name="$1" f v=""
    for f in /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf; do
        [[ -f "${f}" ]] || continue
        v="$(sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*$/\1/p" "${f}" | tail -1)"
    done
    echo "${v}"
}

find_mok() {
    local key="${CMPUNLOCKER_MOK_KEY:-}" cert="${CMPUNLOCKER_MOK_CERT:-}"
    if [[ -z "${key}" || -z "${cert}" ]]; then
        key="$(dkms_conf_value mok_signing_key)"
        cert="$(dkms_conf_value mok_certificate)"
    fi
    if [[ ! -f "${key}" || ! -f "${cert}" ]]; then
        key="${SHIM_MOK_DIR}/MOK.priv"
        cert="${SHIM_MOK_DIR}/MOK.der"
    fi
    [[ -f "${key}" && -f "${cert}" ]] || return 1
    MOK_KEY="${key}"
    MOK_CERT="${cert}"
}

create_mok() {
    command -v update-secureboot-policy &>/dev/null \
        || die "update-secureboot-policy not found; install the shim-signed package"
    mkdir -p "${SHIM_MOK_DIR}"
    SHIM_NOTRIGGER=y update-secureboot-policy --new-key >/dev/null 2>&1 || true
    find_mok || die "update-secureboot-policy --new-key did not create ${SHIM_MOK_DIR}/MOK.der"
    ok "Created ${MOK_CERT}"
}

find_sign_tool() {
    local t
    for t in "/lib/modules/${KVER}/build/scripts/sign-file" \
             "/lib/modules/${KVER}/source/scripts/sign-file" \
             "$(command -v kmodsign 2>/dev/null || true)"; do
        if [[ -n "${t}" && -x "${t}" ]]; then
            SIGN_TOOL="${t}"
            return 0
        fi
    done
    return 1
}

module_signed() {
    [[ -n "$(modinfo -F sig_key "$1" 2>/dev/null || true)" ]]
}

cert_fingerprint() {
    openssl x509 -inform DER -in "$1" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//'
}

ensure_enrolled() {
    local fp pw
    if ! command -v mokutil &>/dev/null; then
        warn "mokutil not found; enroll ${MOK_CERT} in the firmware MOK list yourself before rebooting"
        return 0
    fi
    if [[ "$(mokutil --test-key "${MOK_CERT}" 2>/dev/null || true)" == *"already enrolled"* ]]; then
        ok "Signing key is enrolled in the MOK list"
        return 0
    fi
    fp="$(cert_fingerprint "${MOK_CERT}")"
    fp="${fp,,}"
    if [[ -n "${fp}" && "$(mokutil --list-new 2>/dev/null | tr 'A-F' 'a-f' || true)" == *"${fp}"* ]]; then
        warn "Signing key enrollment is already pending; finish it in MokManager on the next boot"
        return 0
    fi
    pw="$(printf '%08u' "$(( $(od -An -N4 -tu4 /dev/urandom) % 100000000 ))")"
    printf '%s\n%s\n' "${pw}" "${pw}" | mokutil --import "${MOK_CERT}" >/dev/null \
        || die "mokutil --import ${MOK_CERT} failed; enroll the key manually and rerun"
    mokutil --timeout -1 >/dev/null 2>&1 || true
    mkdir -p "${STATE_DIR}"
    ( umask 077; printf '%s\n' "${pw}" > "${STATE_DIR}/enroll-password" )
    warn "Secure Boot is on and the signing key is not enrolled yet"
    echo "  On the next boot the blue MokManager screen appears. Choose:"
    echo "    Enroll MOK -> Continue -> Yes -> enter the password below -> Reboot"
    echo -e "  One-time enrollment password: ${CYAN}${pw}${NC}  (also in ${STATE_DIR}/enroll-password)"
    echo "  The patched modules only load after this enrollment."
}

do_prepare() {
    require_ubuntu
    if secure_boot_enabled; then
        info "Secure Boot is enabled; patched modules will be signed"
        find_sign_tool || die "No module signing tool found; install linux-headers-${KVER} (scripts/sign-file) or sbsigntool (kmodsign)"
        find_mok || create_mok
        ok "Signing key: ${MOK_KEY}"
        ensure_enrolled
    else
        info "Secure Boot is disabled"
        if find_mok && find_sign_tool; then
            ok "Modules will still be signed with ${MOK_CERT}"
        else
            info "No signing key on this system; modules are left unsigned"
        fi
    fi
}

do_sign() {
    local ko failed=0
    require_ubuntu
    if ! find_mok || ! find_sign_tool; then
        if secure_boot_enabled; then
            die "Secure Boot is enabled but no signing key or tool is available; run: sudo ./tools/sign-modules.sh prepare"
        fi
        info "No signing key or tool on this system; leaving modules unsigned"
        return 0
    fi
    for ko in "$@"; do
        [[ -f "${ko}" ]] || { warn "missing ${ko}"; failed=1; continue; }
        if module_signed "${ko}"; then
            ok "Already signed: $(basename "${ko}")"
            continue
        fi
        if "${SIGN_TOOL}" sha256 "${MOK_KEY}" "${MOK_CERT}" "${ko}" 2>/dev/null && module_signed "${ko}"; then
            ok "Signed $(basename "${ko}")"
        else
            warn "Could not sign ${ko}"
            failed=1
        fi
    done
    (( failed == 0 )) || return 1
    return 0
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./tools/sign-modules.sh ..."
case "${1:-}" in
    prepare) do_prepare ;;
    sign)
        shift
        [[ $# -ge 1 ]] || { usage; exit 1; }
        do_sign "$@"
        ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 1 ;;
esac
