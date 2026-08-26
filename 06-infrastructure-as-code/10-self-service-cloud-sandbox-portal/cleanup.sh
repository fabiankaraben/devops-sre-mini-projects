#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Standalone Teardown and Sanitation Script
# ==============================================================================
# Stops the portal server, removes the emulator container, purges all sandbox
# workspaces, state files, logs, and database records.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="localstack-sandbox-portal"
PORTAL_PORT=8080
PURGE_ALL=false

for arg in "$@"; do
    case "$arg" in
        --all)
            PURGE_ALL=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all      Purge container, workspaces, logs, binaries, and database records"
            echo "  --help, -h Show this help message"
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
echo "  🧹 Cleaning Up Self-Service Cloud Sandbox Portal Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Terminate background portal server if running
echo -e "${CLR_YELLOW}▶ [1/4] Stopping portal server instances...${CLR_RESET}"
if [[ -f "logs/server.pid" ]]; then
    PID=$(cat "logs/server.pid" 2>/dev/null || echo "")
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Stopped portal server (PID: ${PID})."
    fi
    rm -f "logs/server.pid"
fi

# Also kill any leftover process listening on port 8080 if started by this user
lsof -ti :${PORTAL_PORT} 2>/dev/null | xargs kill -9 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port ${PORTAL_PORT} cleared."

# Step 2: Remove LocalStack emulator container
echo -e "\n${CLR_YELLOW}▶ [2/4] Stopping and removing emulator container (${CONTAINER_NAME})...${CLR_RESET}"
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container '${CONTAINER_NAME}' removed."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] Container '${CONTAINER_NAME}' not running."
fi

# Step 3: Remove generated sandbox workspaces and state
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging sandbox workspaces, state, and database...${CLR_RESET}"
rm -rf workspaces/ data/
find templates/ -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
find templates/ -type f -name ".terraform.lock.hcl" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Ephemeral workspaces and database cleared."

# Step 4: Remove logs and compiled binaries
echo -e "\n${CLR_YELLOW}▶ [4/4] Purging execution logs and compiled binaries...${CLR_RESET}"
rm -rf logs/ *.log portal-server __pycache__/
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Logs and binaries cleared."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: Environment is clean and ready for subsequent mini-projects.${CLR_RESET}\n"
