#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource & Container Cleanup for Mini-Project 05
# ==============================================================================
# Purges:
#   1. Deployment containers (app-staging, app-production)
#   2. Local build outputs (dist, coverage, .nyc_output)
#   3. Deployment reports (deployment_report_*.json)
#   4. Optional purge of node_modules and images
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./cleanup.sh [OPTIONS]

Cleanup script for GitLab CI Multi-Environment Delivery Pipeline.

Options:
  --full      Also remove node_modules and local docker image
  -h, --help  Display this help message

Examples:
  ./cleanup.sh         # Clean deployment containers, dist, coverage, and reports
  ./cleanup.sh --full  # Clean everything including node_modules and images
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            FULL_CLEAN=true
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

echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}🧹 Cleaning Up GitLab CI Multi-Environment Resources...${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"

# 1. Stop and remove deployment containers
if command -v docker >/dev/null 2>&1; then
    echo -e "${CLR_YELLOW}[1/4] Stopping and removing deployment containers...${CLR_RESET}"
    CONTAINERS=$(docker ps -a --filter "name=app-staging" --filter "name=app-production" --format "{{.ID}}" 2>/dev/null || true)
    if [[ -n "$CONTAINERS" ]]; then
        docker rm -f $CONTAINERS >/dev/null 2>&1 || true
        echo -e "${CLR_GREEN}✓ Removed active deployment containers (app-staging, app-production).${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}✓ No active deployment containers found.${CLR_RESET}"
    fi

    # Optional image clean
    if [[ "$FULL_CLEAN" == "true" ]]; then
        echo -e "${CLR_YELLOW}[2/4] Removing built container image...${CLR_RESET}"
        docker rmi multi-env-delivery-app:local >/dev/null 2>&1 || true
        echo -e "${CLR_GREEN}✓ Container image removed.${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}[2/4] Skipping image removal (use --full to remove image).${CLR_RESET}"
    fi
else
    echo -e "${CLR_YELLOW}[1/4] Docker not detected; skipping container cleanup.${CLR_RESET}"
fi

# 3. Remove build artifacts, test reports, and deployment JSON records
echo -e "${CLR_YELLOW}[3/4] Purging build directories, coverage reports, and deployment records...${CLR_RESET}"
rm -rf "${SCRIPT_DIR}/dist"
rm -rf "${SCRIPT_DIR}/coverage"
rm -rf "${SCRIPT_DIR}/.nyc_output"
rm -rf "${SCRIPT_DIR}/deployment_report_staging.json"
rm -rf "${SCRIPT_DIR}/deployment_report_production.json"
echo -e "${CLR_GREEN}✓ Local build and deployment records removed.${CLR_RESET}"

# 4. Optional full cleanup
if [[ "$FULL_CLEAN" == "true" ]]; then
    echo -e "${CLR_YELLOW}[4/4] Performing full cleanup (removing node_modules)...${CLR_RESET}"
    rm -rf "${SCRIPT_DIR}/node_modules"
    echo -e "${CLR_GREEN}✓ node_modules removed.${CLR_RESET}"
else
    echo -e "${CLR_YELLOW}[4/4] Skipping node_modules (use --full to remove dependencies).${CLR_RESET}"
fi

echo -e "\n${CLR_BOLD}${CLR_GREEN}✨ Environment cleanup complete! The workspace is pristine.${CLR_RESET}\n"
