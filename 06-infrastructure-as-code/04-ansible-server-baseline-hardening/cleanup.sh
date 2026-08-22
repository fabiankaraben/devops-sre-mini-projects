#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Standalone Teardown Script for Server Hardening Mini-Project
# ==============================================================================
# Purges all containers, images, temporary SSH keys, and Ansible caches.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="ansible-hardening-target"
IMAGE_NAME="ansible-hardening-test-node:latest"
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
            echo "  --all      Purge Docker containers, test Docker images, SSH keys, and caches"
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
echo "  🧹 Cleaning Up Ansible Server Hardening Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Stop and remove test container
echo -e "${CLR_YELLOW}▶ [1/4] Stopping and removing test container...${CLR_RESET}"
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container '${CONTAINER_NAME}' removed."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Container '${CONTAINER_NAME}' not found."
fi

# Step 2: Remove test Docker image if --all
echo -e "\n${CLR_YELLOW}▶ [2/4] Managing Docker test images...${CLR_RESET}"
if [[ "$PURGE_ALL" == true ]]; then
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
        docker rmi -f "${IMAGE_NAME}" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Image '${IMAGE_NAME}' removed."
    else
        echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Image '${IMAGE_NAME}' not present."
    fi
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Retaining cached image '${IMAGE_NAME}' (use --all to remove)."
fi

# Step 3: Remove generated test SSH keys
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging temporary test credentials...${CLR_RESET}"
rm -f .ssh_test_key .ssh_test_key.pub
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary SSH test keys deleted."

# Step 4: Remove temporary Ansible logs and generated inventory
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary files & Ansible caches...${CLR_RESET}"
rm -f inventory.ini *.retry /tmp/ansible_run_*.log
rm -rf .ansible/ __pycache__/ .pytest_cache/
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All logs, caches, and generated inventories purged."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All project resources have been successfully purged.${CLR_RESET}\n"
