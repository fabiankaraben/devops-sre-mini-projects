#!/usr/bin/env bash
# ==============================================================================
# setup_multi_region.sh - Bootstraps Multi-Region Blue-Green Stack
# ==============================================================================
# Automates:
#   1. Tool verification (docker, curl, jq, python3)
#   2. Building and launching the Multi-Region stack via Docker Compose
#   3. Polling Global Edge Router and Regional Backends until ready
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"
GATEWAY_URL="http://localhost:8090"
MAX_WAIT_SEC=30

mkdir -p "$SANDBOX_DIR"

show_help() {
    cat <<EOF
Usage: ./setup_multi_region.sh [OPTIONS]

Builds and starts the Multi-Region Blue-Green deployment infrastructure.

Options:
  -h, --help      Display this help message

Examples:
  ./setup_multi_region.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 Multi-Region Blue-Green Deployment Stack: Setup & Launch"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Verify Prerequisites
echo -e "${CLR_YELLOW}▶ [1/3] Verifying CLI prerequisites...${CLR_RESET}"
for bin in docker curl jq python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Required tool '${bin}' is not installed or not in PATH." >&2
        exit 1
    fi
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Found: ${bin} ($(command -v "$bin"))"
done

if ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Docker daemon is not running." >&2
    exit 1
fi
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Docker daemon is running."

# 2. Build and Launch Containers
echo -e "\n${CLR_YELLOW}▶ [2/3] Building and starting Multi-Region Blue-Green Docker containers...${CLR_RESET}"
cd "$SCRIPT_DIR"
docker compose up -d --build

# 3. Wait for Global Edge Router & Regional Nodes
echo -e "\n${CLR_YELLOW}▶ [3/3] Waiting for Global Edge Router at ${GATEWAY_URL}/health...${CLR_RESET}"
READY=false
for ((i=1; i<=MAX_WAIT_SEC; i++)); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/health" || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        READY=true
        break
    fi
    echo -ne "  [Elapsed: ${i}s] Waiting for global router and upstreams... (HTTP ${HTTP_CODE})\r"
    sleep 1
done

if [[ "$READY" == true ]]; then
    echo -e "\n  [${CLR_GREEN}✓${CLR_RESET}] Multi-Region Blue-Green Gateway is ONLINE and healthy!"
else
    echo -e "\n  [${CLR_RED}ERROR${CLR_RESET}] Timed out waiting for Global Edge Router." >&2
    docker compose logs
    exit 1
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 Multi-Region Blue-Green Infrastructure Provisioned!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Global Live Gateway:   ${CLR_CYAN}${GATEWAY_URL}/api/info${CLR_RESET}"
echo -e "  • Router Status API:     ${CLR_CYAN}${GATEWAY_URL}/admin/status${CLR_RESET}"
echo -e "  • Multi-Region Backends: ${CLR_BOLD}us-east (Blue/Green), eu-west (Blue/Green)${CLR_RESET}"
echo ""
echo -e "  ${CLR_BOLD}Next Steps:${CLR_RESET}"
echo -e "    Inspect environment status:"
echo -e "    ${CLR_CYAN}./blue_green_orchestrator.py status${CLR_RESET}"
echo ""
echo -e "    Run the automated zero-downtime test suite:"
echo -e "    ${CLR_GREEN}${CLR_BOLD}./test_orchestration.sh${CLR_RESET}"
echo ""
