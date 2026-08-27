#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 10-08
# ==============================================================================
# Cleans generated postmortem reports, Python caches, Docker containers,
# and container images, leaving the local environment completely clean.
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

IMAGE_NAME="sre-incident-postmortem-generator:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_IMAGES=false

for arg in "$@"; do
    case "$arg" in
        --all|--purge-images)
            PURGE_IMAGES=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-images   Remove Docker images ($IMAGE_NAME) and containers"
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
echo "  🧹 Cleaning Up Incident Timeline & Postmortem Generator Stack"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Stop and remove Docker containers
echo -e "${CLR_YELLOW}▶ [1/3] Removing Docker Compose containers...${CLR_RESET}"
if command -v docker >/dev/null 2>&1; then
    docker compose down --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Containers stopped and removed."
fi

# 2. Optionally purge Docker images
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging Docker container image ($IMAGE_NAME)...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1 && docker images -q "$IMAGE_NAME" 2>/dev/null | grep -q .; then
        docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Image '$IMAGE_NAME' removed."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Image '$IMAGE_NAME' not found or already deleted."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all to purge Docker images).${CLR_RESET}"
fi

# 3. Clean generated reports and cache files
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing generated reports and temporary python caches...${CLR_RESET}"
rm -rf "$SCRIPT_DIR/reports"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local report directory and cache cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
