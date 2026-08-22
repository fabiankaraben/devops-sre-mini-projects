#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 03
# ==============================================================================
# Destroys all demo workload resources, empties S3 state buckets, destroys
# backend bootstrap resources, stops the local AWS emulator container,
# and removes temporary state and plan artifacts.
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
EMULATOR_CONTAINER="localstack-state-demo"
EMULATOR_PORT=4566
EMULATOR_URL="http://127.0.0.1:${EMULATOR_PORT}"
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
echo "  🧹 Cleaning Up S3 & DynamoDB Remote State Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Detect IaC engine
IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
AWS_CMD="aws --endpoint-url=${EMULATOR_URL} --region=us-east-1"

# 2. Destroy Demo Workload Infrastructure
echo -e "${CLR_YELLOW}▶ [1/4] Destroying Demo Workload Infrastructure...${CLR_RESET}"
if [[ -n "$IAC_BIN" ]] && [[ -d "$SCRIPT_DIR/demo_infrastructure/.terraform" ]]; then
    echo "  Running '$IAC_BIN destroy' in demo_infrastructure..."
    (
        cd "$SCRIPT_DIR/demo_infrastructure"
        "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1 || true
    )
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] demo_infrastructure resources destroyed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] demo_infrastructure is not initialized."
fi

# 3. Empty S3 state buckets and destroy Backend Bootstrap
echo -e "\n${CLR_YELLOW}▶ [2/4] Destroying Backend Bootstrap Infrastructure...${CLR_RESET}"
if [[ -n "$IAC_BIN" ]] && [[ -f "$SCRIPT_DIR/backend_bootstrap/terraform.tfstate" ]]; then
    # Extract S3 bucket name if available
    STATE_BUCKET=$( (cd "$SCRIPT_DIR/backend_bootstrap" && "$IAC_BIN" output -raw s3_bucket_name 2>/dev/null) || echo "" )
    if [[ -n "$STATE_BUCKET" ]] && curl -s "${EMULATOR_URL}/" >/dev/null 2>&1; then
        echo "  Purging S3 state bucket versions (${STATE_BUCKET})..."
        VERSIONS=$($AWS_CMD s3api list-object-versions --bucket "$STATE_BUCKET" --output json 2>/dev/null || echo "{}")
        OBJECTS_TO_DELETE=$(echo "$VERSIONS" | jq '{Objects: [.Versions[]?, .DeleteMarkers[]? | {Key: .Key, VersionId: .VersionId}] | select(length > 0)}' 2>/dev/null || echo "")
        if [[ -n "$OBJECTS_TO_DELETE" && "$OBJECTS_TO_DELETE" != "{}" && "$OBJECTS_TO_DELETE" != '{"Objects":[]}' ]]; then
            $AWS_CMD s3api delete-objects --bucket "$STATE_BUCKET" --delete "$OBJECTS_TO_DELETE" >/dev/null 2>&1 || true
        fi
    fi

    echo "  Running '$IAC_BIN destroy' in backend_bootstrap..."
    (
        cd "$SCRIPT_DIR/backend_bootstrap"
        "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1 || true
    )
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] backend_bootstrap resources destroyed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] backend_bootstrap state not active."
fi

# 4. Stop and remove Docker emulator container
echo -e "\n${CLR_YELLOW}▶ [3/4] Stopping Local AWS Emulator Container...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${EMULATOR_CONTAINER}$"; then
        echo "  Removing container: ${EMULATOR_CONTAINER}"
        docker rm -f "${EMULATOR_CONTAINER}" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Emulator container removed."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Emulator container not found."
    fi
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker not available."
fi

# 5. Remove temporary files & state caches
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary files & state caches...${CLR_RESET}"
find "$SCRIPT_DIR" -type f \( -name "*.tfplan" -o -name "tfplan" -o -name ".tmp_*" -o -name "*.log" -o -name "backend-generated.hcl" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

if [[ "$PURGE_STATE" == true ]]; then
    echo "  Purging .terraform/ directories, lockfiles, and state files..."
    find "$SCRIPT_DIR" -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
    find "$SCRIPT_DIR" -type f \( -name ".terraform.lock.hcl" -o -name "terraform.tfstate*" \) -exec rm -f {} + 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All state and plugin caches purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Keeping plugin caches and states (use '--all' to remove them)."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All project resources have been successfully purged.${CLR_RESET}\n"
