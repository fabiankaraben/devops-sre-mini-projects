#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource & Artifact Cleanup for Mini-Project 01
# ==============================================================================
# Purges:
#   1. Docker containers spawned during local matrix simulation
#   2. Local build artifacts (dist, coverage, .nyc_output)
#   3. Optional purge of node_modules and caches
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

Cleanup script for GitHub Actions Matrix Lint and Test Workflow.

Options:
  --full      Also remove node_modules and pnpm store lock artifacts
  -h, --help  Display this help message

Examples:
  ./cleanup.sh         # Clean test containers, dist, coverage, and temp files
  ./cleanup.sh --full  # Clean everything including node_modules
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
echo -e "${CLR_BOLD}${CLR_CYAN}🧹 Cleaning Up GitHub Actions Matrix Mini-Project Resources...${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"

# 1. Stop and remove Docker containers
if command -v docker >/dev/null 2>&1; then
    echo -e "${CLR_YELLOW}[1/3] Scanning for active/stopped CI matrix test containers...${CLR_RESET}"
    CONTAINERS=$(docker ps -a --filter "name=ci-matrix-runner-" --format "{{.ID}}" 2>/dev/null || true)
    if [[ -n "$CONTAINERS" ]]; then
        echo -e "${CLR_CYAN}Removing containers:${CLR_RESET}"
        docker rm -f $CONTAINERS
        echo -e "${CLR_GREEN}✓ Matrix containers removed successfully.${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}✓ No matrix test containers found.${CLR_RESET}"
    fi
else
    echo -e "${CLR_YELLOW}[1/3] Docker not detected; skipping container cleanup.${CLR_RESET}"
fi

# 2. Remove build and test artifacts
echo -e "${CLR_YELLOW}[2/3] Purging build directories, coverage reports, and temp caches...${CLR_RESET}"
rm -rf "${SCRIPT_DIR}/dist"
rm -rf "${SCRIPT_DIR}/coverage"
rm -rf "${SCRIPT_DIR}/.nyc_output"
rm -rf "${SCRIPT_DIR}/.tmp_ci_test"
echo -e "${CLR_GREEN}✓ Local build and coverage artifacts removed.${CLR_RESET}"

# 3. Optional full cleanup
if [[ "$FULL_CLEAN" == "true" ]]; then
    echo -e "${CLR_YELLOW}[3/3] Performing full cleanup (removing node_modules)...${CLR_RESET}"
    rm -rf "${SCRIPT_DIR}/node_modules"
    echo -e "${CLR_GREEN}✓ node_modules removed.${CLR_RESET}"
else
    echo -e "${CLR_YELLOW}[3/3] Skipping node_modules (use --full to remove dependencies).${CLR_RESET}"
fi

echo -e "\n${CLR_BOLD}${CLR_GREEN}✨ Environment cleanup complete! The workspace is pristine.${CLR_RESET}\n"
