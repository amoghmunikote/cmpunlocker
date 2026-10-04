#!/bin/bash
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

banner() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║               cmpunlocker              ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
}

STEP_NUM=0
STEP_TOTAL=0
step_init() { STEP_TOTAL="$1"; STEP_NUM=0; }

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Step ${STEP_NUM}/${STEP_TOTAL}: $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

normalize_bus_id() {
    local raw="$1"
    raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [[ "${raw}" =~ ^([0-9a-f]+):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$ ]]; then
        printf '%04x:%s:%s.%s\n' "$((16#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    elif [[ "${raw}" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
        echo "0000:${raw}"
    else
        echo "${raw}"
    fi
}

profile_from_devid() {
    case "$1" in
        20c2) echo "8gb" ;;
        2082) echo "10gb" ;;
        *) echo "unsupported" ;;
    esac
}

expected_mib_for_profile() {
    case "$1" in
        8gb) echo "65536" ;;
        10gb) echo "40960" ;;
        *) echo "" ;;
    esac
}

smi_memory_for_bus() {
    local want="$1"
    local line bus mem
    [[ -n "${SMI_MEM_CACHE:-}" ]] || return 0
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        bus="$(normalize_bus_id "$(echo "${line}" | cut -d, -f1)")"
        mem="$(echo "${line}" | cut -d, -f2 | tr -d '[:space:]')"
        if [[ "${bus}" == "${want}" ]]; then
            echo "${mem}"
            return 0
        fi
    done <<< "${SMI_MEM_CACHE}"
}
