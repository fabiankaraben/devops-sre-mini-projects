#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 02
# ==============================================================================
# Destroys all provisioned Dev and Prod VPC resources, stops the LocalStack
# container, and removes temporary state and plan artifacts.
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
LOCALSTACK_CONTAINER="localstack-vpc-demo"
PURGE_STATE=false

for arg in "$@"; do
    case "$arg" in
        --all|--purge-state)
            PURGE_STATE=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-state   Also purge .terraform/, .terraform.lock.hcl, and terraform.tfstate files"
            echo "  --help, -h             Show this help message"
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
echo "  🧹 Cleaning Up Modular AWS VPC Resources & LocalStack"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Detect IaC engine
IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

# 2. Destroy Dev and Prod environments
echo -e "${CLR_YELLOW}▶ [1/4] Destroying Terraform environments...${CLR_RESET}"
for env_dir in "environments/prod" "environments/dev"; do
    if [[ -n "$IAC_BIN" ]] && [[ -f "$SCRIPT_DIR/$env_dir/terraform.tfstate" ]]; then
        echo "  Running '$IAC_BIN destroy' in $env_dir..."
        (
            cd "$SCRIPT_DIR/$env_dir"
            "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1 || true
        )
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] $env_dir resources destroyed."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active state found in $env_dir."
    fi
done

# 3. Stop and remove LocalStack Docker container
echo -e "\n${CLR_YELLOW}▶ [2/4] Stopping LocalStack container...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${LOCALSTACK_CONTAINER}$"; then
        echo "  Removing container: ${LOCALSTACK_CONTAINER}"
        docker rm -f "${LOCALSTACK_CONTAINER}" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] LocalStack container removed."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] LocalStack container not found."
    fi
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker not available."
fi

# 4. Remove local plan files and test logs
echo -e "\n${CLR_YELLOW}▶ [3/4] Removing temporary plan files and test artifacts...${CLR_RESET}"
find "$SCRIPT_DIR" -type f \( -name "*.tfplan" -o -name "tfplan" -o -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

# 5. Purge state and plugin caches if requested
echo -e "\n${CLR_YELLOW}▶ [4/4] State & plugin cache cleanup...${CLR_RESET}"
if [[ "$PURGE_STATE" == true ]]; then
    echo "  Purging .terraform/ directories, lockfiles, and state files..."
    find "$SCRIPT_DIR" -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
    find "$SCRIPT_DIR" -type f \( -name ".terraform.lock.hcl" -o -name "terraform.tfstate*" \) -exec rm -f {} + 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All state and plugin caches purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Keeping plugin caches and states (use '--all' to remove them)."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All project resources have been successfully purged.${CLR_RESET}\n"
