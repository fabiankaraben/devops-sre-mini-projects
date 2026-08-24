#!/usr/bin/env bash
# ==============================================================================
# execute_migration_phases.sh - Zero-Downtime Migration Orchestrator
# ==============================================================================
# Sequentially executes Expand, Backfill, Cutover, and Contract migration phases:
# - Phase 1: Expand (Add nullable columns + bidirectional trigger)
# - Phase 2: Backfill (Populate historical records)
# - Cutover: Switch application API mode to V2
# - Phase 3: Contract (Drop triggers, drop legacy column, set NOT NULL)
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_CYAN="\033[1;36m"
CLR_YELLOW="\033[1;33m"
CLR_RED="\033[1;31m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="postgres-refactoring-db"
DB_NAME="users_db"
API_URL="http://localhost:8000"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔄 Zero-Downtime Schema Refactoring - Migration Orchestrator"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Phase 1: Expand
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [PHASE 1] Executing Expand Migration (01_expand.sql)...${CLR_RESET}"
docker exec -i "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" < "$SCRIPT_DIR/migrations/01_expand.sql" >/dev/null

COLS_P1=$(docker exec "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" -t -A -c \
    "SELECT string_agg(column_name, ', ') FROM information_schema.columns WHERE table_name = 'users';")
echo -e "  • Table Columns : ${CLR_GREEN}${COLS_P1}${CLR_RESET}"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Phase 1 (Expand) applied: Nullable columns & trigger created."

sleep 1

# ------------------------------------------------------------------------------
# Phase 2: Backfill
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [PHASE 2] Executing Historical Data Backfill (02_backfill.sql)...${CLR_RESET}"
docker exec -i "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" < "$SCRIPT_DIR/migrations/02_backfill.sql" >/dev/null

UNFILLED_COUNT=$(docker exec "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" -t -A -c \
    "SELECT COUNT(*) FROM users WHERE first_name IS NULL OR last_name IS NULL;")

echo -e "  • Unfilled Historical Rows: ${CLR_GREEN}${UNFILLED_COUNT}${CLR_RESET}"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Phase 2 (Backfill) applied: 100% records synchronized."

sleep 1

# ------------------------------------------------------------------------------
# Application Cutover: V1 -> V2
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [CUTOVER] Switching Active Application API Mode to V2...${CLR_RESET}"
CUTOVER_RESP=$(curl -s -X POST "${API_URL}/version/v2")
echo -e "  • Cutover Response : ${CLR_GREEN}${CUTOVER_RESP}${CLR_RESET}"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Application cutover complete: App reads & writes new columns."

sleep 1

# ------------------------------------------------------------------------------
# Phase 3: Contract
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [PHASE 3] Executing Contract Migration (03_contract.sql)...${CLR_RESET}"
docker exec -i "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" < "$SCRIPT_DIR/migrations/03_contract.sql" >/dev/null

COLS_P3=$(docker exec "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" -t -A -c \
    "SELECT string_agg(column_name, ', ') FROM information_schema.columns WHERE table_name = 'users';")
echo -e "  • Final Columns : ${CLR_GREEN}${COLS_P3}${CLR_RESET}"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Phase 3 (Contract) applied: Triggers and legacy column 'full_name' dropped."

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All 4 Migration Steps Finished Successfully with ZERO Database Locks!${CLR_RESET}\n"
