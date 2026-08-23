#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 10-01
# ==============================================================================
# Stops and removes Docker containers, networks, volumes (Prometheus TSDB data),
# temporary Python/test files, and optionally removes downloaded Docker images.
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
            echo "  --all, --purge-images   Remove Prometheus and Mock Service container images as well"
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
echo "  🧹 Cleaning Up SLI, SLO & Error Budget Calculator Stack"
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
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down containers, network, and TSDB named volumes...${CLR_RESET}"

if [[ -n "$COMPOSE_CMD" ]] && [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Containers 'prometheus-sre' and 'mock-service' stopped and removed."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Network 'sre-calculator-net' removed."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Named volume 'prometheus_sre_data' deleted."
else
    # Fallback to direct docker removal if compose is unavailable
    if command -v docker >/dev/null 2>&1; then
        docker rm -f prometheus-sre mock-service >/dev/null 2>&1 || true
        docker volume rm prometheus_sre_data >/dev/null 2>&1 || true
        docker network rm sre-calculator-net >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Direct Docker cleanup completed."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging Prometheus and Mock Service container images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f sre-mock-metrics:latest prometheus-sre-stack:v2.54.1 prom/prometheus:v2.54.1 python:3.11-slim >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images 'sre-mock-metrics:latest' and 'prometheus-sre-stack:v2.54.1' removed."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete them).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Temporary Python & Local Test Artifacts
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary test artifacts, reports and cache...${CLR_RESET}"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
rm -f "$SCRIPT_DIR/slo_report.md" "$SCRIPT_DIR/slo_report.json"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files and generated reports cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
