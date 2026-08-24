#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Comprehensive HashiCorp Vault Environment Teardown Script
# ==============================================================================
# Cleans up all Docker containers, networks, volumes, temporary credentials,
# and caches generated during Vault secrets engine operation, leaving the
# environment completely pristine for subsequent mini-projects.
#
# Usage:
#   ./cleanup.sh         # Standard teardown (containers, volumes, tokens, caches)
#   ./cleanup.sh --all   # Complete teardown (also removes Vault & Postgres Docker images)
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_IMAGES=false

if [[ "${1:-}" == "--all" || "${1:-}" == "--purge-images" ]]; then
    PURGE_IMAGES=true
fi

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🧹 Cleaning Up HashiCorp Vault Secrets Engine Resources"
echo "======================================================================${CLR_RESET}"

# 1. Stop and Remove Docker Containers, Volumes, and Networks
echo -e "\n${CLR_YELLOW}▶ [1/3] Tearing down containers, volumes, and networks...${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    
    # Remove standalone container instances if any exist
    docker rm -f vault-server vault-postgres-db >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Vault and Postgres containers and named volumes removed."
fi

# 2. Purge Docker Images (Optional / --all)
echo -e "\n${CLR_YELLOW}▶ [2/3] Purging Docker images...${CLR_RESET}"

if [ "$PURGE_IMAGES" = true ]; then
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f hashicorp/vault:1.15.5 >/dev/null 2>&1 || true
        docker rmi -f postgres:15-alpine >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images 'hashicorp/vault:1.15.5' and 'postgres:15-alpine' removed."
    fi
else
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Retaining base images for fast local reuse. Run './cleanup.sh --all' to purge."
fi

# 3. Clean Generated Secrets, Credentials, Tokens, and Caches
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary tokens, credentials, and caches...${CLR_RESET}"

rm -f "$SCRIPT_DIR/vault_init_keys.json"
rm -f "$SCRIPT_DIR/app/config/approle_creds.json"
rm -f "$SCRIPT_DIR"/*.token
rm -f "$SCRIPT_DIR"/.vault-token
rm -rf "$SCRIPT_DIR/data"
rm -rf "$SCRIPT_DIR/vault_data"
rm -rf "$SCRIPT_DIR/postgres_data"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name ".DS_Store" -delete 2>/dev/null || true

mkdir -p "$SCRIPT_DIR/app/config"
touch "$SCRIPT_DIR/app/config/.gitkeep"

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Generated credentials and local caches cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
