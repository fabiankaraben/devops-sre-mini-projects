#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Comprehensive Resource Teardown Script
# ==============================================================================
# Cleans up all Docker containers, networks, volumes, temporary reports,
# and caches generated during IaC security scanning, leaving the environment
# completely pristine for subsequent mini-projects.
#
# Usage:
#   ./cleanup.sh         # Standard teardown (containers, reports, caches)
#   ./cleanup.sh --all   # Complete teardown (also removes Docker scanner images)
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_IMAGES=false

if [[ "${1:-}" == "--all" || "${1:-}" == "--purge-images" ]]; then
    PURGE_IMAGES=true
fi

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🧹 Cleaning Up IaC Security Scanning Resources"
echo "======================================================================${CLR_RESET}"

# 1. Stop and Remove Docker Containers and Compose Stack
echo -e "\n${CLR_YELLOW}▶ [1/3] Tearing down containers and compose networks...${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    
    # Remove standalone container instances if any exist
    if docker ps -a --format '{{.Names}}' | grep -q "^checkov-iac-scanner-sandbox$"; then
        docker rm -f checkov-iac-scanner-sandbox >/dev/null 2>&1 || true
    fi
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Compose containers and networks stopped and removed."
fi

# 2. Purge Container Images (Optional / --all)
echo -e "\n${CLR_YELLOW}▶ [2/3] Purging Docker images...${CLR_RESET}"

if [ "$PURGE_IMAGES" = true ]; then
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f checkov-iac-scanner:v1.0.0 >/dev/null 2>&1 || true
        docker rmi -f bridgecrew/checkov:latest >/dev/null 2>&1 || true
        docker rmi -f aquasec/tfsec:latest >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Scanner images 'checkov-iac-scanner:v1.0.0', 'bridgecrew/checkov', and 'aquasec/tfsec' removed."
    fi
else
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Retaining base scanner images for fast local reuse. Run './cleanup.sh --all' to purge."
fi

# 3. Clean Local Reports, Caches, and Python Bytecode
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary reports, cache, and Python artifacts...${CLR_RESET}"

rm -rf "$SCRIPT_DIR/reports"/*
rm -rf "$SCRIPT_DIR/.checkov_cache"
rm -rf "$SCRIPT_DIR/.terraform"
rm -rf "$SCRIPT_DIR"/.terraform.lock.hcl
rm -rf "$SCRIPT_DIR"/terraform.tfstate*
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name ".DS_Store" -delete 2>/dev/null || true

# Recreate empty reports placeholder
mkdir -p "$SCRIPT_DIR/reports"
touch "$SCRIPT_DIR/reports/.gitkeep"

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Generated scan reports and caches cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
