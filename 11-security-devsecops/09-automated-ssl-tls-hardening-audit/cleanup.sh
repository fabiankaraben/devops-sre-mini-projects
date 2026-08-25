#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 11-09
# ==============================================================================
# Stops and removes Docker Compose containers, networks, volumes, generated
# PKI certificates, reports, and optionally purges built Docker images.
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
            echo "  --all, --purge-images   Remove created Docker container images as well"
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
echo "  🧹 Cleaning Up SSL/TLS Cipher Hardening Audit Sandbox Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Stop and Remove Docker Compose Containers
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down Docker Compose containers and networks...${CLR_RESET}"

COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

if [[ -n "$COMPOSE_CMD" ]]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Containers (weak-tls-server, hardened-tls-server) removed."
fi

# ------------------------------------------------------------------------------
# 2. Optionally Remove Docker Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Removing built Docker images...${CLR_RESET}"
    docker rmi -f weak-tls-server:latest hardened-tls-server:latest nginx:alpine >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images purged."
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Preserving Docker images (use --all or --purge-images to remove)...${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Certificates, Reports, and Logs
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Cleaning generated certificates, reports, and logs...${CLR_RESET}"
rm -rf "$SCRIPT_DIR/certs"
rm -rf "$SCRIPT_DIR/reports"
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Generated PKI certs and local report artifacts removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is clean! Ready for subsequent projects.${CLR_RESET}\n"
