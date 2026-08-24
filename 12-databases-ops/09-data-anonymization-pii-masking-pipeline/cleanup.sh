#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Complete Resource Teardown for Mini-Project 12-09
# ==============================================================================
# Stops and removes Docker Compose containers, networks, volumes, generated
# SQL dumps, audit reports, and temporary Python caches.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_IMAGES=false
KEEP_DUMPS=false

for arg in "$@"; do
    case "$arg" in
        --all|--purge-images)
            PURGE_IMAGES=true
            ;;
        --keep-dumps)
            KEEP_DUMPS=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-images   Remove PostgreSQL container images as well"
            echo "  --keep-dumps            Retain generated sanitized SQL dumps & reports"
            echo "  --help, -h              Show this help message"
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
echo "  🧹 Data Anonymization Pipeline - Environment Teardown"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Stop and Remove Docker Containers, Networks, and Volumes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down Docker Compose containers & volumes...${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker containers, volumes, and networks removed."
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging PostgreSQL container images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f postgres:16-alpine >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] PostgreSQL images purged."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete images).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Generated Dumps, Reports, and Python Caches
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Cleaning generated SQL dumps, reports, and python caches...${CLR_RESET}"

if [ "$KEEP_DUMPS" = false ]; then
    rm -rf "$SCRIPT_DIR/dumps" "$SCRIPT_DIR/reports" "$SCRIPT_DIR"/*.log "$SCRIPT_DIR"/*.tmp
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] SQL dumps and audit reports removed."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Preserved dumps/ and reports/ (--keep-dumps enabled)."
fi

find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Python bytecode and cache cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
