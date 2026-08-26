#!/usr/bin/env bash
# ==============================================================================
# OpenSearch Index Lifecycle Management (ISM) - Automated Test Suite
# ==============================================================================
set -e

# Terminal Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  ⚙️  OpenSearch Index State Management (ISM) - Test Runner${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker is not installed or not in PATH."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker engine is active."

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker Compose is required."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose: ${COMPOSE_CMD}"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is required."
    exit 1
fi
PYTHON_VER=$(python3 --version 2>&1)
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python runtime: ${PYTHON_VER}"

# ------------------------------------------------------------------------------
# 2. Start OpenSearch and OpenSearch Dashboards Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Starting OpenSearch & Dashboards Stack...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo -e "  Waiting for OpenSearch (:9200) and OpenSearch Dashboards (:5601)..."

MAX_WAIT=120
RETRY=0
OS_READY=false
DASHBOARDS_READY=false

while [ $RETRY -lt $MAX_WAIT ]; do
    if [ "$OS_READY" = false ]; then
        if curl -s -f "http://127.0.0.1:9200/_cluster/health" 2>/dev/null | grep -Eq '"status":"(green|yellow)"'; then
            OS_READY=true
            echo -e "  [${CLR_GREEN}READY${CLR_RESET}] OpenSearch cluster is healthy."
        fi
    fi

    if [ "$DASHBOARDS_READY" = false ]; then
        if curl -s -f "http://127.0.0.1:5601/api/status" 2>/dev/null | grep -q '"state":"green"'; then
            DASHBOARDS_READY=true
            echo -e "  [${CLR_GREEN}READY${CLR_RESET}] OpenSearch Dashboards is available."
        fi
    fi

    if [ "$OS_READY" = true ] && [ "$DASHBOARDS_READY" = true ]; then
        break
    fi

    sleep 3
    RETRY=$((RETRY + 3))
    echo -e "  ${CLR_GRAY}Still initializing services (${RETRY}s/${MAX_WAIT}s)...${CLR_RESET}"
done

if [ "$OS_READY" = false ] || [ "$DASHBOARDS_READY" = false ]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Stack failed to become healthy in ${MAX_WAIT}s."
    $COMPOSE_CMD ps
    exit 1
fi

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] OpenSearch stack is ready for ISM lifecycle execution."

# ------------------------------------------------------------------------------
# 3. Execute ISM Lifecycle Simulation & Validation Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Running ISM Tiered Storage Lifecycle Simulation...${CLR_RESET}"
python3 simulate_ism_lifecycle.py

# ------------------------------------------------------------------------------
# 4. Final Status & Instructions
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [4/4] Validation Complete!${CLR_RESET}"
echo -e "  ${CLR_CYAN}👉 OpenSearch Dashboards:${CLR_RESET} http://localhost:5601"
echo -e "  ${CLR_CYAN}👉 Index Management UI:${CLR_RESET}   http://localhost:5601/app/opensearch_index_management_dashboards#/indices"
echo -e "  ${CLR_CYAN}👉 ISM Policies UI:${CLR_RESET}       http://localhost:5601/app/opensearch_index_management_dashboards#/policies\n"

echo -e "${CLR_GREEN}${CLR_BOLD}✨ OpenSearch Index Lifecycle Management (ISM) tests completed successfully!${CLR_RESET}\n"
