#!/bin/bash
set -euo pipefail

registry="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"
case "${1:-0}" in
    0) ;;
    1) registry+=";RMForceStaticBar1=1;RMPcieP2PType=1" ;;
    *) echo "Usage: module-options.sh [0|1]" >&2; exit 1 ;;
esac
printf 'options nvidia NVreg_RegistryDwords="%s"\n' "${registry}"
