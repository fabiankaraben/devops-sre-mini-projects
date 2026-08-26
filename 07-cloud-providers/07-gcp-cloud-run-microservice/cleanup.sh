#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Resource Cleanup for Project 07
# ==============================================================================
# Purges local Docker containers, images, volumes, background test processes,
# and cleans up Google Cloud Platform infrastructure (via Terraform).
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

PURGE_ALL=false
VERBOSE=false

show_help() {
    echo -e "${CLR_BOLD}Usage:${CLR_RESET} ./cleanup.sh [OPTIONS]"
    echo ""
    echo -e "${CLR_BOLD}Options:${CLR_RESET}"
    echo "  --all          Purge all artifacts including .terraform/ cache and lockfiles"
    echo "  --verbose, -v  Show verbose cleanup output"
    echo "  --help, -h     Show this help message"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            PURGE_ALL=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up GCP Cloud Run Microservice Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Kill Lingering Background Processes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background web servers and benchmarks...${CLR_RESET}"
pkill -f "python3.*app/main.py" 2>/dev/null || true
pkill -f "benchmark_cloud_run.sh" 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Background processes terminated."

# ------------------------------------------------------------------------------
# 2. Stop and Purge Docker Containers, Networks & Local Images
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Stopping and removing Docker containers, networks & volumes...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
        echo "  Running 'docker compose down -v --rmi local'..."
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" down -v --rmi local --remove-orphans >/dev/null 2>&1 || true
    fi

    # Explicit container cleanup
    CONTAINERS=$(docker ps -a --filter "name=gcp-cloud-run" -q 2>/dev/null || true)
    if [[ -n "$CONTAINERS" ]]; then
        echo "  Removing lingering containers: $CONTAINERS"
        docker rm -f $CONTAINERS >/dev/null 2>&1 || true
    fi

    # Explicit image cleanup
    IMAGES=$(docker images --filter "reference=*gcp-cloud-run*" -q 2>/dev/null || true)
    if [[ -n "$IMAGES" ]]; then
        echo "  Removing local images: $IMAGES"
        docker rmi -f $IMAGES >/dev/null 2>&1 || true
    fi

    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker resources and local images purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker daemon not running. Skipping container teardown."
fi

# ------------------------------------------------------------------------------
# 3. Destroy Terraform / OpenTofu Cloud Infrastructure
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Destroying Terraform / OpenTofu Cloud Infrastructure...${CLR_RESET}"
IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

if [[ -n "$IAC_BIN" ]] && [[ -f "$SCRIPT_DIR/terraform.tfstate" ]]; then
    # Check if there are active resources in state
    RESOURCE_COUNT=$("$IAC_BIN" state list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$RESOURCE_COUNT" -gt 0 ]]; then
        echo -e "  Found ${RESOURCE_COUNT} managed cloud resources in state. Destroying with '$IAC_BIN destroy'..."
        "$IAC_BIN" destroy -auto-approve "$SCRIPT_DIR"
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cloud infrastructure destroyed."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] State file exists but contains 0 resources."
    fi
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active Terraform state found. Skipping cloud destroy."
fi

# ------------------------------------------------------------------------------
# 4. Remove Temporary Files and Local Logs
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary files and test logs...${CLR_RESET}"

rm -f "$SCRIPT_DIR/test_report.json" \
      "$SCRIPT_DIR/test_benchmark_results.json" \
      "$SCRIPT_DIR/tfplan" \
      "$SCRIPT_DIR"/*.log \
      "$SCRIPT_DIR"/app/*.pyc \
      2>/dev/null || true

rm -rf "$SCRIPT_DIR/app/__pycache__" \
       "$SCRIPT_DIR/__pycache__" \
       2>/dev/null || true

if [[ "$PURGE_ALL" == true ]]; then
    echo "  Purging Terraform cache (.terraform/), lock files, and state..."
    rm -rf "$SCRIPT_DIR/.terraform" \
           "$SCRIPT_DIR/.terraform.lock.hcl" \
           "$SCRIPT_DIR/terraform.tfstate" \
           "$SCRIPT_DIR/terraform.tfstate.backup" \
           2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All local caches and state files purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Preserved .terraform/ cache (run with --all to remove)."
fi

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ Teardown Complete! Environment is clean and ready.${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
