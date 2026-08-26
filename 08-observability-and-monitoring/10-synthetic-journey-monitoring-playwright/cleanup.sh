#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 08-10
# ==============================================================================
# Stops and removes all Docker Compose containers, networks, and volumes,
# deletes captured failure screenshots, cleans temporary files, and optionally
# purges built container images.
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

for arg in "$@"; do
    case "$arg" in
        --all|--purge-images)
            PURGE_IMAGES=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-images   Purge built container images after teardown"
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
echo "  🧹 Cleaning Up Synthetic Journey Monitoring Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Stop and Remove Containers, Networks, and Volumes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Stopping & Removing Docker Compose Stack...${CLR_RESET}"

if command -v docker compose >/dev/null 2>&1; then
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Containers, networks, and named volumes removed."
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging project Docker images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        IMAGES_TO_REMOVE=(
            "synthetic-target-app"
            "synthetic-agent"
            "synthetic-prometheus"
            "synthetic-grafana"
            "10-synthetic-journey-monitoring-playwright-target-app"
            "10-synthetic-journey-monitoring-playwright-synthetic-agent"
            "10-synthetic-journey-monitoring-playwright-prometheus"
            "10-synthetic-journey-monitoring-playwright-grafana"
        )
        for img in "${IMAGES_TO_REMOVE[@]}"; do
            docker rmi -f "$img" >/dev/null 2>&1 || true
        done
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Project container images purged."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete them).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Screenshots and Temporary Cache
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Cleaning failure screenshots and temporary files...${CLR_RESET}"
rm -f "$SCRIPT_DIR/screenshots"/failure_*.png 2>/dev/null || true
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary artifacts and screenshots removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean and ready for subsequent mini-projects!${CLR_RESET}\n"
