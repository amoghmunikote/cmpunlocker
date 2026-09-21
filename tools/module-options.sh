#!/bin/bash
set -euo pipefail

registry=""
stream=""
case "${2:-0}" in
    0) registry="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1;" ;;
    1) ;;
    *) echo "Gen2 disable flag must be 0 or 1" >&2; exit 1 ;;
esac
case "${1:-0}" in
    0|off) ;;
    1|bar1) registry+="RMForceStaticBar1=1;RMPcieP2PType=1;" ;;
    mailbox)
        registry+="PeerMappingOverride=1;ForceP2P=17;"
        stream=" NVreg_EnableStreamMemOPs=1" ;;
    *) echo "Usage: module-options.sh [off|bar1|mailbox] [disable-gen2: 0|1]" >&2; exit 1 ;;
esac
if [[ -n "${registry}" ]]; then
    printf 'options nvidia%s NVreg_RegistryDwords="%s"\n' "${stream}" "${registry%;}"
else
    echo '# No forced PCIe speed or P2P options'
fi
