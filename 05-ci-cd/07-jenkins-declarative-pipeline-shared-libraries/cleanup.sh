#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown & Resource Cleanup for Mini-Project 07
# ==============================================================================
# Purges:
#   1. Jenkins Docker Compose stack (containers, networks, volumes)
#   2. Local image artifacts (jenkins-shared-lib-controller)
#   3. Orphaned agent containers spawned during pipeline execution
#   4. Local test sandboxes (.tmp_sandbox, test logs, artifacts)
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"

KEEP_IMAGES=false

show_help() {
    cat <<EOF
Usage: ./cleanup.sh [OPTIONS]

Stops and removes Jenkins controller containers, volumes, networks, and temporary files.

Options:
  --keep-images   Retain built Docker images for fast subsequent startups
  -h, --help      Display this help message

Examples:
  ./cleanup.sh               # Complete purge of containers, volumes, and images
  ./cleanup.sh --keep-images # Purge containers and volumes, keep Docker images
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-images)
            KEEP_IMAGES=true
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Jenkins Controller, Agents & Docker Environment"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Stop and remove Docker Compose services and volumes
echo -e "${CLR_YELLOW}▶ [1/3] Stopping and removing Jenkins Docker Compose stack...${CLR_RESET}"
cd "$SCRIPT_DIR"

if docker compose ps -q >/dev/null 2>&1; then
    if [[ "$KEEP_IMAGES" == true ]]; then
        docker compose down -v
    else
        docker compose down -v --rmi local 2>/dev/null || docker compose down -v
    fi
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Docker Compose services and volumes removed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active Docker Compose services found."
fi

# 2. Prune any orphaned Jenkins agent containers or volumes
echo -e "\n${CLR_YELLOW}▶ [2/3] Pruning orphaned Jenkins containers and volumes...${CLR_RESET}"
ORPHAN_CONTAINERS=$(docker ps -a --filter "name=jenkins-shared-lib" -q 2>/dev/null || true)
if [[ -n "$ORPHAN_CONTAINERS" ]]; then
    echo "  Removing container(s): $ORPHAN_CONTAINERS"
    # shellcheck disable=SC2086
    docker rm -f $ORPHAN_CONTAINERS >/dev/null 2>&1 || true
fi

ORPHAN_VOLUMES=$(docker volume ls --filter "name=jenkins_shared_lib" -q 2>/dev/null || true)
if [[ -n "$ORPHAN_VOLUMES" ]]; then
    echo "  Removing volume(s): $ORPHAN_VOLUMES"
    # shellcheck disable=SC2086
    docker volume rm -f $ORPHAN_VOLUMES >/dev/null 2>&1 || true
fi

if [[ "$KEEP_IMAGES" == false ]]; then
    docker rmi -f jenkins-shared-lib-controller:latest >/dev/null 2>&1 || true
fi
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Lingering Docker resources purged."

# 3. Clean temporary files and test sandboxes
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary sandboxes and logs...${CLR_RESET}"
if [[ -d "$SANDBOX_DIR" ]]; then
    rm -rf "$SANDBOX_DIR"
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Sandbox directory '${SANDBOX_DIR}' removed."
fi
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Temporary files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ CLEANUP COMPLETE: All Jenkins resources successfully purged!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
