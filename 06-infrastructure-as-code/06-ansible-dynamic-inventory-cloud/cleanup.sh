#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown and Sanitation Script
# ==============================================================================
# Purges simulated fleet containers, Docker bridge networks, custom images,
# Ansible local execution caches, and logs to leave a pristine environment.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="ansible-fleet-node:latest"
NETWORK_NAME="ansible-fleet-net"
FLEET_LABEL="devops.fleet=ansible-dynamic-inventory"
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
            echo "  --all      Purge Docker containers, network, Docker images, logs, and caches"
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
echo "  🧹 Cleaning Up Ansible Dynamic Inventory Fleet Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Remove fleet containers
echo -e "${CLR_YELLOW}▶ [1/4] Stopping and removing fleet containers...${CLR_RESET}"
CONTAINERS=$(docker ps -a --filter "label=${FLEET_LABEL}" --format '{{.Names}}' 2>/dev/null || true)
if [[ -n "$CONTAINERS" ]]; then
    while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        docker rm -f "$cname" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container '${cname}' removed."
    done <<< "$CONTAINERS"
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] No fleet containers active."
fi

# Step 2: Remove Docker network
echo -e "\n${CLR_YELLOW}▶ [2/4] Removing Docker network '${NETWORK_NAME}'...${CLR_RESET}"
if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Network '${NETWORK_NAME}' removed."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Network '${NETWORK_NAME}' not present."
fi

# Step 3: Manage Docker image
echo -e "\n${CLR_YELLOW}▶ [3/4] Managing Docker images...${CLR_RESET}"
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

# Step 4: Remove local Ansible temporary artifacts and logs within this project directory
echo -e "\n${CLR_YELLOW}▶ [4/4] Purging local caches and logs...${CLR_RESET}"
rm -rf .ansible/ logs/ __pycache__/ .pytest_cache/ *.retry
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Project caches and logs purged."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: Environment is clean and ready for subsequent mini-projects.${CLR_RESET}\n"
