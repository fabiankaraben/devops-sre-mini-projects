#!/usr/bin/env bash
# ==============================================================================
# Teardown & Resource Cleanup: Vector Log Sanitization and PII Masking
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
echo -e "${CLR_CYAN}${CLR_BOLD}  🧹 Cleaning Up Vector PII Sanitization Resources${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

# ------------------------------------------------------------------------------
# 1. Stop and remove containers and volumes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down containers, networks, and volumes...${CLR_RESET}"

if [ -n "$COMPOSE_CMD" ]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
fi

# Force removal of container if still present
if docker ps -a --format '{{.Names}}' | grep -q "^vector-sanitizer$"; then
    docker rm -f vector-sanitizer >/dev/null 2>&1 || true
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vector container 'vector-sanitizer' stopped and removed."

# Remove volume if lingering
if docker volume ls -q | grep -q "^vector_sanitized_data$"; then
    docker volume rm -f vector_sanitized_data >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Volume 'vector_sanitized_data' deleted."
fi

# Remove network if lingering
if docker network ls --format '{{.Name}}' | grep -q "^vector-sanitizer-net$"; then
    docker network rm vector-sanitizer-net >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Network 'vector-sanitizer-net' removed."
fi

# ------------------------------------------------------------------------------
# 2. Optional: Remove Docker Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Removing Vector Docker images...${CLR_RESET}"
    docker rmi -f mini-proj-09-07-vector:local >/dev/null 2>&1 || true
    docker rmi -f timberio/vector:0.41.0-alpine >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local and base Vector Docker images removed."
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete them).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean temporary local files
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary Python cache and log files...${CLR_RESET}"
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
find . -type f -name "*.log" -not -path "*/sample_logs/*" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✅ Environment is completely clean and ready for subsequent mini-projects!${CLR_RESET}\n"
