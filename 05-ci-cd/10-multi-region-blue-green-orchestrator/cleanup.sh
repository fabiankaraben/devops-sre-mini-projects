#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown & Resource Cleanup for Mini-Project 10
# ==============================================================================
# Purges:
#   1. Multi-Region Docker Compose stack and containers
#   2. Multi-Region application and proxy Docker images
#   3. Local test sandboxes (.tmp_sandbox/, logs, state files)
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

KEEP_IMAGES=false

show_help() {
    cat <<EOF
Usage: ./cleanup.sh [OPTIONS]

Stops and removes the Multi-Region Blue-Green Docker stack, images, and temporary files.

Options:
  --keep-images   Retain built Docker images
  -h, --help      Display this help message

Examples:
  ./cleanup.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-images)
            KEEP_IMAGES=true
            shift
            ;;
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
echo "  🧹 Cleaning Up Multi-Region Blue-Green Stack & Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Stop and remove Docker Compose stack
echo -e "${CLR_YELLOW}▶ [1/3] Stopping and removing Multi-Region container stack...${CLR_RESET}"
cd "$SCRIPT_DIR"
if command -v docker >/dev/null 2>&1; then
    docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Docker Compose stack removed."
fi

# 2. Remove Docker images
echo -e "\n${CLR_YELLOW}▶ [2/3] Removing Multi-Region Docker images...${CLR_RESET}"
if [[ "$KEEP_IMAGES" == false ]]; then
    docker rmi -f \
        10-multi-region-blue-green-orchestrator-global-edge-router:latest \
        10-multi-region-blue-green-orchestrator-app-us-east-blue:latest \
        10-multi-region-blue-green-orchestrator-app-us-east-green:latest \
        10-multi-region-blue-green-orchestrator-app-eu-west-blue:latest \
        10-multi-region-blue-green-orchestrator-app-eu-west-green:latest \
        >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Multi-Region Docker images purged."
else
    echo -e "  [${CLR_BLUE}INFO${CLR_RESET}] Keeping Docker images (--keep-images flag passed)."
fi

# 3. Clean temporary files & sandboxes
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local sandbox directory and temporary state files...${CLR_RESET}"
if [[ -d "$SANDBOX_DIR" ]]; then
    rm -rf "$SANDBOX_DIR"
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Sandbox directory '${SANDBOX_DIR}' removed."
fi
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" -o -name "router_state.json" \) -exec rm -f {} +
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Temporary files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ CLEANUP COMPLETE: All Multi-Region Blue-Green resources purged!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
