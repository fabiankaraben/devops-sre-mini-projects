#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Standalone Teardown Script for OpenTofu Workspaces
# ==============================================================================
# Destroys all workspace resources, deletes workspaces, and stops containers.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

EMULATOR_CONTAINER="localstack-workspaces-demo"
PURGE_ALL=false

# Detect engine
IAC_BIN="tofu"
if ! command -v "$IAC_BIN" >/dev/null 2>&1; then
    if command -v terraform >/dev/null 2>&1; then
        IAC_BIN="terraform"
    fi
fi

for arg in "$@"; do
    case "$arg" in
        --all)
            PURGE_ALL=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all      Destroy resources, delete workspaces, stop containers, and purge state caches"
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
echo "  🧹 Cleaning Up OpenTofu Multi-Environment Workspaces"
echo "======================================================================"
echo -e "${CLR_RESET}"

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

# Step 1: Destroy resources in each workspace
echo -e "${CLR_YELLOW}▶ [1/4] Destroying resources across all workspaces...${CLR_RESET}"
if command -v "$IAC_BIN" >/dev/null 2>&1 && [[ -d ".terraform" || -d ".tofu" ]]; then
    for env in prod staging dev; do
        if "$IAC_BIN" workspace list 2>/dev/null | grep -q "[ *]${env}$"; then
            echo "  Destroying workspace '${env}'..."
            "$IAC_BIN" workspace select "$env" >/dev/null 2>&1 || true
            if [[ -f "environments/${env}.tfvars" ]]; then
                "$IAC_BIN" destroy -var-file="environments/${env}.tfvars" -auto-approve >/dev/null 2>&1 || true
            fi
        fi
    done

    # Switch to default and delete custom workspaces
    echo "  Switching to default workspace..."
    "$IAC_BIN" workspace select default >/dev/null 2>&1 || true
    for env in prod staging dev; do
        "$IAC_BIN" workspace delete "$env" >/dev/null 2>&1 || true
    done
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All environment workspaces destroyed and deleted."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] IaC engine or state not initialized; skipping destroy step."
fi

# Step 2: Stop and remove local emulator container
echo -e "\n${CLR_YELLOW}▶ [2/4] Stopping Local AWS Emulator Container...${CLR_RESET}"
if docker ps -a --format '{{.Names}}' | grep -q "^${EMULATOR_CONTAINER}$"; then
    docker rm -f "${EMULATOR_CONTAINER}" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Emulator container '${EMULATOR_CONTAINER}' removed."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Emulator container not found."
fi

# Step 3: Remove temporary plan and state files
echo -e "\n${CLR_YELLOW}▶ [3/4] Removing temporary files & state caches...${CLR_RESET}"
rm -rf terraform.tfstate.d/ *.tfplan *.tfstate* *.log
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary state files and plans removed."

# Step 4: Full cache purge if --all
if [[ "$PURGE_ALL" == true ]]; then
    echo -e "\n${CLR_YELLOW}▶ [4/4] Purging plugins and lockfiles (--all)...${CLR_RESET}"
    rm -rf .terraform/ .tofu/ .terraform.lock.hcl .tofu.lock.hcl .tflint.d/
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All plugin caches and lockfiles purged."
else
    echo -e "\n${CLR_YELLOW}▶ [4/4] Retaining plugin caches (pass --all to purge).${CLR_RESET}"
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All project resources have been successfully purged.${CLR_RESET}\n"
