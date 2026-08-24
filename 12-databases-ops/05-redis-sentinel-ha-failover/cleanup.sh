#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Complete Resource Teardown for Mini-Project 12-05
# ==============================================================================
# Stops and removes all 6 Docker containers (redis-master, redis-replica-1,
# redis-replica-2, redis-sentinel-1, redis-sentinel-2, redis-sentinel-3),
# networks, volumes, local benchmark reports, logs, python cache, and optionally
# purges downloaded container images.
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
            echo "  --all, --purge-images   Remove Redis container images (redis:7-alpine)"
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
echo "  🧹 Redis Sentinel HA & Failover - Environment Teardown"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Determine Docker Compose CLI syntax
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

# ------------------------------------------------------------------------------
# 1. Stop and Remove Containers, Networks, and Named Volumes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down 6 Redis & Sentinel containers and networks...${CLR_RESET}"

if [[ -n "$COMPOSE_CMD" ]] && [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All 6 cluster containers removed."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Network 'redis-sentinel-net' removed."
else
    if command -v docker >/dev/null 2>&1; then
        docker rm -f redis-master redis-replica-1 redis-replica-2 redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 >/dev/null 2>&1 || true
        docker network rm redis-sentinel-net >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Direct Docker cleanup completed."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging Redis container images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f redis:7-alpine >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker image 'redis:7-alpine' removed."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete images).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Local Reports, Logs, and Python Cache
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local reports, test artifacts, and python cache...${CLR_RESET}"
rm -f "$SCRIPT_DIR"/*.log "$SCRIPT_DIR"/failover_report.json "$SCRIPT_DIR"/resilience_results.json
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary reports and python cache files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
