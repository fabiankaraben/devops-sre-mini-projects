#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource & Artifact Teardown for Mini-Project 04
# ==============================================================================
# Purges:
#   1. Active or stopped scanner containers
#   2. Local test Docker images (vulnerable-test-app, secure-test-app, test-app)
#   3. Generated JSON, SARIF, and Markdown security reports
#   4. Python bytecode and test caches
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
PURGE_IMAGES=false

show_help() {
    cat <<EOF
Usage: ./cleanup.sh [OPTIONS]

Cleanup script for Multi-Stage Security Scanning Pipeline.

Options:
  --images    Also remove tagged Docker test images (vulnerable-test-app, secure-test-app)
  -h, --help  Display this help message

Examples:
  ./cleanup.sh          # Remove generated reports, caches, and test containers
  ./cleanup.sh --images # Remove all test containers, reports, and tagged Docker images
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --images)
            PURGE_IMAGES=true
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
echo -e "${CLR_BOLD}${CLR_CYAN}🧹 Cleaning Up Security Scanning Pipeline Resources...${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    # 1. Stop and remove any residual scanner containers
    echo -e "${CLR_YELLOW}[1/3] Removing lingering scanner containers...${CLR_RESET}"
    CONTAINERS=$(docker ps -a --filter "ancestor=zricethezav/gitleaks:latest" --filter "ancestor=semgrep/semgrep" --filter "ancestor=aquasec/trivy:latest" --format "{{.ID}}" 2>/dev/null || true)
    if [[ -n "$CONTAINERS" ]]; then
        docker rm -f $CONTAINERS >/dev/null 2>&1 || true
        echo -e "${CLR_GREEN}✓ Removed active/stopped scanner containers.${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}✓ No residual scanner containers found.${CLR_RESET}"
    fi

    # 2. Prune test images if requested
    if [[ "$PURGE_IMAGES" == "true" ]]; then
        echo -e "${CLR_YELLOW}[2/3] Pruning test images...${CLR_RESET}"
        docker rmi -f vulnerable-test-app:latest secure-test-app:latest test-app:local >/dev/null 2>&1 || true
        echo -e "${CLR_GREEN}✓ Test Docker images pruned.${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}[2/3] Skipping Docker image pruning (use --images to delete tagged test images).${CLR_RESET}"
    fi
else
    echo -e "${CLR_YELLOW}Docker not available; skipping container teardown.${CLR_RESET}"
fi

# 3. Clean generated reports and caches
echo -e "${CLR_YELLOW}[3/3] Purging generated report files and Python caches...${CLR_RESET}"
rm -rf "${SCRIPT_DIR}/reports"
rm -rf "${SCRIPT_DIR}/downloaded_reports"
rm -rf "${SCRIPT_DIR}/.pytest_cache"
rm -rf "${SCRIPT_DIR}/__pycache__"
rm -rf "${SCRIPT_DIR}/tests/__pycache__"
rm -rf "${SCRIPT_DIR}"/*.sarif "${SCRIPT_DIR}"/*.json "${SCRIPT_DIR}"/*.md.tmp 2>/dev/null || true

echo -e "${CLR_GREEN}✓ Reports directory and temporary caches cleared.${CLR_RESET}"

echo -e "\n${CLR_BOLD}${CLR_GREEN}✨ Security pipeline cleanup complete! The environment is pristine.${CLR_RESET}\n"
