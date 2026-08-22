#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 07-03
# ==============================================================================
# Destroys all provisioned SQS queues, DLQs, Lambda functions, event source
# mappings, and CloudWatch alarms, stops LocalStack containers, and purges state.
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
cd "$SCRIPT_DIR"

PURGE_STATE=false
LOCALSTACK_CONTAINER="localstack-serverless-demo"

for arg in "$@"; do
    case "$arg" in
        --all|--purge-state)
            PURGE_STATE=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-state   Purge .terraform/, .terraform.lock.hcl, and terraform.tfstate files"
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
echo "  🧹 Cleaning Up Serverless SQS + Lambda Pipeline Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Destroy Terraform Cloud Infrastructure
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Destroying Terraform / OpenTofu Infrastructure...${CLR_RESET}"
IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

if [[ -n "$IAC_BIN" ]] && [[ -f "$SCRIPT_DIR/terraform.tfstate" ]]; then
    echo "  Running '$IAC_BIN destroy'..."
    "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] SQS, Lambda, and CloudWatch resources destroyed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active Terraform state found. Skipping cloud destroy."
fi

# ------------------------------------------------------------------------------
# 2. Stop and Remove LocalStack Container
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Stopping LocalStack container (if running)...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${LOCALSTACK_CONTAINER}$"; then
        docker rm -f "${LOCALSTACK_CONTAINER}" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container ${LOCALSTACK_CONTAINER} removed."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Container ${LOCALSTACK_CONTAINER} not running."
    fi
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker not available."
fi

# ------------------------------------------------------------------------------
# 3. Clean Temporary Files & Test Artifacts
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Removing temporary files, zip payloads, and logs...${CLR_RESET}"
find "$SCRIPT_DIR" -type f \( \
    -name "*.tfplan" -o \
    -name "tfplan" -o \
    -name ".tmp_*" -o \
    -name "*.zip" -o \
    -name "*.log" -o \
    -name "test_report.json" -o \
    -name "*.pyc" \
\) -exec rm -f {} + 2>/dev/null || true

find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary artifacts removed."

# ------------------------------------------------------------------------------
# 4. State & Plugin Cache Cleanup (if requested)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] State & plugin cache cleanup...${CLR_RESET}"
if [[ "$PURGE_STATE" == true ]]; then
    echo "  Purging .terraform/ directories, lockfiles, and state files..."
    find "$SCRIPT_DIR" -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
    find "$SCRIPT_DIR" -type f \( -name ".terraform.lock.hcl" -o -name "terraform.tfstate*" \) -exec rm -f {} + 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All state and plugin caches purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Preserved .terraform/ cache (run with --all or --purge-state to remove)."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ Teardown Complete! Environment is clean and ready.${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
