#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Standalone Teardown and Sanitation Script
# ==============================================================================
# Purges the LocalStack container, Terraform state files, binary plans,
# parsed JSON diffs, Slack alert logs, and temporary caches.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="localstack-drift-demo"
PURGE_ALL=false

for arg in "$@"; do
    case "$arg" in
        --all)
            PURGE_ALL=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all      Purge container, state, binary plans, and log caches"
            echo "  --help, -h Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./cleanup.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Terraform Drift Detection Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Remove LocalStack emulator container
echo -e "${CLR_YELLOW}▶ [1/3] Stopping and removing emulator container (${CONTAINER_NAME})...${CLR_RESET}"
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container '${CONTAINER_NAME}' removed."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Container '${CONTAINER_NAME}' not running."
fi

# Step 2: Remove Terraform state, locks, and plugins
echo -e "\n${CLR_YELLOW}▶ [2/3] Purging Terraform caches, state, and lock files...${CLR_RESET}"
rm -rf terraform/.terraform terraform/.terraform.lock.hcl
rm -f terraform/*.tfstate terraform/*.tfstate.* terraform/*.tfplan*
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Terraform local state and plugin caches purged."

# Step 3: Remove logs, binary plans, and JSON payloads
echo -e "\n${CLR_YELLOW}▶ [3/3] Purging generated plans, payloads, and execution logs...${CLR_RESET}"
rm -rf logs/ *.log __pycache__/ tests/__pycache__/
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Drift logs and artifacts cleared."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: Environment is clean and ready for subsequent mini-projects.${CLR_RESET}\n"
