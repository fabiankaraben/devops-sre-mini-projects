#!/usr/bin/env bash
# ==============================================================================
# Teardown & Resource Cleanup: Log-Based Metrics Extraction & Alerting
# ==============================================================================
set -e

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
        --all|--purge-images|-a)
            PURGE_IMAGES=true
            ;;
    esac
done

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  🧹 Cleaning Up Log-Based Metrics & Alerting Resources${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

# ------------------------------------------------------------------------------
# 1. Stop and remove containers, networks, and storage volumes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down containers, network, and storage volumes...${CLR_RESET}"

if [ -n "$COMPOSE_CMD" ]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
fi

# Explicit container cleanup
docker rm -f log-alert-nginx log-alert-promtail log-alert-loki log-alert-prometheus log-alert-alertmanager >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All containers removed."

# Volume cleanup
VOLS=("shared_nginx_logs" "loki_log_data" "prometheus_log_data" "alertmanager_log_data")
for v in "${VOLS[@]}"; do
    if docker volume ls -q | grep -q "^${v}$"; then
        docker volume rm -f "$v" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Volume '${v}' deleted."
    fi
done

# Network cleanup
if docker network ls --format '{{.Name}}' | grep -q "^log-metrics-net$"; then
    docker network rm log-metrics-net >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Network 'log-metrics-net' removed."
fi

# ------------------------------------------------------------------------------
# 2. Optional: Remove Docker Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging project Docker images...${CLR_RESET}"
    docker rmi -f mini-proj-09-09-nginx:local mini-proj-09-09-promtail:local mini-proj-09-09-loki:local mini-proj-09-09-prometheus:local mini-proj-09-09-alertmanager:local >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local project images purged."
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete them).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean temporary local files
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary Python cache and log files...${CLR_RESET}"
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
find . -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✅ Environment is completely clean and ready for subsequent mini-projects!${CLR_RESET}\n"
