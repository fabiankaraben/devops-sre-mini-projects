#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource & Artifact Cleanup for Mini-Project 03
# ==============================================================================
# Purges:
#   1. Ephemeral simulation sandbox repositories (.tmp_sandbox)
#   2. Local build outputs (dist, coverage, .nyc_output)
#   3. Optional purge of node_modules
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

Cleanup script for Semantic Release and Automated Changelog.

Options:
  --full      Also remove node_modules and pnpm store lock artifacts
  -h, --help  Display this help message

Examples:
  ./cleanup.sh         # Clean simulation sandbox, dist, coverage, and temp files
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
echo -e "${CLR_BOLD}${CLR_CYAN}🧹 Cleaning Up Semantic Release Mini-Project Resources...${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"

# 1. Remove isolated simulation sandbox
echo -e "${CLR_YELLOW}[1/3] Removing isolated test sandbox...${CLR_RESET}"
rm -rf "${SCRIPT_DIR}/.tmp_sandbox"
echo -e "${CLR_GREEN}✓ Ephemeral test sandbox removed.${CLR_RESET}"

# 2. Remove build and test artifacts
echo -e "${CLR_YELLOW}[2/3] Purging build directories, coverage reports, and temp caches...${CLR_RESET}"
rm -rf "${SCRIPT_DIR}/dist"
rm -rf "${SCRIPT_DIR}/coverage"
rm -rf "${SCRIPT_DIR}/.nyc_output"
rm -rf "${SCRIPT_DIR}/CHANGELOG.md"
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
