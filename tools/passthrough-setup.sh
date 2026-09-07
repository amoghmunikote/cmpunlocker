#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

KVER="${CMPUNLOCKER_KVER:-$(uname -r)}"
MOD_SRC="${SCRIPT_DIR}/../driver/passthrough"
MOD_DST="/lib/modules/${KVER}/updates/cmpunlocker"
LIB="/usr/local/lib/cmpunlocker"
CONSTANTS="${SCRIPT_DIR}/../common/constants.yaml"

[[ "${EUID}" -eq 0 ]] || die "passthrough-setup.sh must run as root"

info "Building cmp_no_bus_reset.ko"
make -C "${MOD_SRC}" KVER="${KVER}" clean &>/dev/null || true
if ! make -C "${MOD_SRC}" KVER="${KVER}" &>/dev/null; then
    warn "could not build cmp_no_bus_reset.ko; passthrough support not installed"
    warn "the unlock still works on this host, but a VM would reset the card"
    exit 0
fi
install -D -m 0644 "${MOD_SRC}/cmp_no_bus_reset.ko" "${MOD_DST}/cmp_no_bus_reset.ko"
depmod -a "${KVER}"
ok "Installed cmp_no_bus_reset.ko"

mkdir -p "${LIB}"

python3 - "${CONSTANTS}" "${LIB}/gsp-regs.conf" <<'PY'
import io, sys
import yaml
cpath, out = sys.argv[1:3]
with io.open(cpath, encoding="utf-8") as f:
    c = yaml.safe_load(f) or {}
regs = ((c.get("passthrough") or {}).get("gsp_boot_state") or {})
if not regs:
    raise SystemExit("constants.yaml has no passthrough.gsp_boot_state")
lines = ["# generated from common/constants.yaml by cmpunlocker install.sh",
         "# <addr> <value> <name>"]
for name in sorted(regs):
    r = regs[name]
    lines.append("%s %s %s" % (r["addr"], r["value"], name))
io.open(out, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
print("wrote %s (%d registers)" % (out, len(regs)))
PY
ok "Wrote ${LIB}/gsp-regs.conf"

install -m 0755 "${SCRIPT_DIR}/gsp-restore.py"     "${LIB}/gsp-restore"
install -m 0755 "${SCRIPT_DIR}/passthrough-arm.sh" "${LIB}/passthrough-arm"
ok "Installed runtime helpers in ${LIB}"

cat > /etc/systemd/system/cmpunlocker-passthrough.service <<'EOF'
[Unit]
Description=cmpunlocker: arm CMP 170HX cards for VM passthrough
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/cmpunlocker/passthrough-arm

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/udev/rules.d/99-cmpunlocker-passthrough.rules <<'EOF'
# When a CMP 170HX is handed to vfio-pci, put its GSP boot-time registers back so a
# guest can still boot GSP. The card is never reset, so the unlock survives.
ACTION=="bind", SUBSYSTEM=="pci", DRIVER=="vfio-pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x20c2", RUN+="/usr/local/lib/cmpunlocker/gsp-restore %k"
ACTION=="bind", SUBSYSTEM=="pci", DRIVER=="vfio-pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x2082", RUN+="/usr/local/lib/cmpunlocker/gsp-restore %k"
EOF
ok "Installed systemd unit and udev rule"

systemctl daemon-reload
systemctl enable cmpunlocker-passthrough.service &>/dev/null
udevadm control --reload-rules 2>/dev/null || true
ok "Enabled cmpunlocker-passthrough.service for every boot"

if systemctl start cmpunlocker-passthrough.service 2>/dev/null; then
    ok "Armed the cards now (no reboot needed)"
else
    warn "arming service failed; run: systemctl status cmpunlocker-passthrough"
fi
