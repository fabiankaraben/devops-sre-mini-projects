#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 08-06
# ==============================================================================
# Stops and removes Docker containers, networks, volumes, temporary Python
# test artifacts, and optionally removes built Docker images.
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
            echo "  --all, --purge-images   Remove microservice and Jaeger container images"
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
echo "  🧹 Cleaning Up OpenTelemetry & Jaeger Tracing Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Determine Docker Compose CLI
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

# ------------------------------------------------------------------------------
# 1. Stop Containers & Remove Networks and Volumes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down containers and network...${CLR_RESET}"

if [[ -n "$COMPOSE_CMD" ]] && [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Containers 'frontend-service', 'auth-service', 'payment-service', 'jaeger-tracing' stopped and removed."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Bridge network 'tracing-stack-net' removed."
else
    if command -v docker >/dev/null 2>&1; then
        docker rm -f frontend-service auth-service payment-service jaeger-tracing >/dev/null 2>&1 || true
        docker network rm tracing-stack-net >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Direct Docker fallback cleanup completed."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging microservice Docker images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f \
            mini-proj-08-06-frontend-service:local \
            mini-proj-08-06-auth-service:local \
            mini-proj-08-06-payment-service:local \
            jaegertracing/all-in-one:1.57.0 >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container images removed."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete them).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Temporary Files & Cache
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary Python artifacts and caches...${CLR_RESET}"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files and cache directories cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean and ready for subsequent mini-projects!${CLR_RESET}\n"
