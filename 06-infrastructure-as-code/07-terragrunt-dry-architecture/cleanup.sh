#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Standalone Resource Teardown and Sanitation Script
# ==============================================================================
# Purges all Terragrunt caches, generated provider/backend files, LocalStack
# containers, state files, and execution logs to leave a pristine workspace.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="localstack-terragrunt-demo"
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
            echo "  --all      Purge containers, caches, state files, generated HCL, and logs"
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
echo "  🧹 Cleaning Up Terragrunt DRY Multi-Account Architecture Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Remove LocalStack emulator container
echo -e "${CLR_YELLOW}▶ [1/4] Stopping and removing LocalStack container...${CLR_RESET}"
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container '${CONTAINER_NAME}' removed."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Container '${CONTAINER_NAME}' not running."
fi

# Step 2: Remove generated provider and backend files
echo -e "\n${CLR_YELLOW}▶ [2/4] Removing Terragrunt generated files (provider.tf, backend.tf)...${CLR_RESET}"
find . -type f \( -name "provider.tf" -o -name "backend.tf" -o -name ".terraform.lock.hcl" \) -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Dynamically generated HCL files deleted."

# Step 3: Purge Terragrunt and Terraform caches and plans
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging .terragrunt-cache, .terraform, and state files...${CLR_RESET}"
find . -type d -name ".terragrunt-cache" -prune -exec rm -rf {} + 2>/dev/null || true
find . -type d -name ".terraform" -prune -exec rm -rf {} + 2>/dev/null || true
find . -type f \( -name "*.tfstate" -o -name "*.tfstate.*" -o -name "*.tfplan" -o -name "*.log" \) -delete 2>/dev/null || true
rm -rf logs/
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All local caches, plan files, and state files purged."

# Step 4: Manage Docker test images if --all
echo -e "\n${CLR_YELLOW}▶ [4/4] Managing local Docker images...${CLR_RESET}"
if [[ "$PURGE_ALL" == true ]]; then
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Retaining base emulator image for fast subsequent runs."
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local environment sanitized."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: Environment is clean and ready for subsequent mini-projects.${CLR_RESET}\n"
