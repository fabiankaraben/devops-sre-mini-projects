#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Complete Resource Teardown for Mini-Project 12-02
# ==============================================================================
# Stops and removes Docker containers, networks, volumes (PostgreSQL primary,
# replica, and shared WAL archive), reports, python cache, and images.
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
            echo "  --all, --purge-images   Remove PostgreSQL container images as well"
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
echo "  🧹 PostgreSQL Streaming Replication Cluster - Environment Teardown"
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
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down containers, network, and replication volumes...${CLR_RESET}"

if [[ -n "$COMPOSE_CMD" ]] && [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Containers 'postgres-primary' and 'postgres-replica' removed."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Network 'postgres-rep-net' removed."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Named volumes 'postgres_primary_cluster_data', 'postgres_replica_cluster_data', and 'postgres_wal_archive_data' deleted."
else
    if command -v docker >/dev/null 2>&1; then
        docker rm -f postgres-primary postgres-replica >/dev/null 2>&1 || true
        docker volume rm postgres_primary_cluster_data postgres_replica_cluster_data postgres_wal_archive_data >/dev/null 2>&1 || true
        docker network rm postgres-rep-net >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Direct Docker cleanup completed."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging PostgreSQL container images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f postgres:16-alpine >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker image 'postgres:16-alpine' removed."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete images).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Local Reports, Logs, and Python Cache
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local reports, logs, and temporary cache files...${CLR_RESET}"
rm -f "$SCRIPT_DIR/failover_report.json" "$SCRIPT_DIR/replication_report.json" "$SCRIPT_DIR/parity_report.json" "$SCRIPT_DIR"/*.log
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary reports and python cache files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
