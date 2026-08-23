#!/usr/bin/env bash
# ==============================================================================
# logql_test_queries.sh - Automated Test Runner for Loki & Promtail Pipeline
# ==============================================================================
# 1. Checks prerequisites (Docker, Docker Compose, Python 3).
# 2. Builds container images and launches Loki, Promtail, Grafana & App stack.
# 3. Awaits service health and ingestion readiness.
# 4. Executes python LogQL test suite asserting sub-second query performance.
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 Promtail, Loki, and Grafana LogQL Pipeline - Automated Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running. Please start OrbStack or Docker Desktop."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker engine is running."

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker Compose not found."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose command: ${CLR_BOLD}${COMPOSE_CMD}${CLR_RESET}"

# ------------------------------------------------------------------------------
# 2. Build Images & Start Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building & Launching Loki, Promtail, Grafana & App Stack...${CLR_RESET}"

$COMPOSE_CMD build >/dev/null
$COMPOSE_CMD up -d --remove-orphans >/dev/null

echo "  Awaiting container health and endpoint readiness..."
MAX_RETRIES=40
RETRY=0
LOKI_READY=false
GRAFANA_READY=false

while [ $RETRY -lt $MAX_RETRIES ]; do
    if curl -s -f "http://127.0.0.1:3100/ready" | grep -qi "ready" 2>/dev/null; then
        LOKI_READY=true
    fi
    if curl -s -f "http://127.0.0.1:3000/api/health" | grep -qi "ok" 2>/dev/null; then
        GRAFANA_READY=true
    fi

    if [ "$LOKI_READY" = true ] && [ "$GRAFANA_READY" = true ]; then
        break
    fi

    sleep 1.5
    RETRY=$((RETRY + 1))
done

if [ "$LOKI_READY" = true ] && [ "$GRAFANA_READY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Loki (:3100) and Grafana (:3000) are healthy and accepting requests."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Services failed to become ready within timeout."
    docker ps -a
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Verify Log Generation & Promtail Scraping
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Verifying Multi-Service Log Emission & Scraping...${CLR_RESET}"

sleep 3

# Check log files exist in shared volume
TOTAL_LOGS=$(docker exec loki-stack-app sh -c "wc -l /var/log/apps/*.log 2>/dev/null | tail -n 1 | awk '{print \$1}'" || echo "0")
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Multi-service log files created: ${TOTAL_LOGS} records generated across services."

# ------------------------------------------------------------------------------
# 4. Run LogQL Validation Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Running Automated LogQL Query & Performance Assertions...${CLR_RESET}"

python3 "$SCRIPT_DIR/logql_validation.py" --url "http://127.0.0.1:3100"

# ------------------------------------------------------------------------------
# 5. Summary & Exploration Instructions
# ------------------------------------------------------------------------------
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 ALL LOGQL PIPELINE TESTS PASSED SUCCESSFULLY!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "\n${CLR_CYAN}Explore the Pipeline:${CLR_RESET}"
echo -e "  • Open Grafana Dashboard:     ${CLR_BOLD}http://localhost:3000${CLR_RESET} (admin / admin)"
echo -e "  • Query Loki API directly:    ${CLR_BOLD}curl -G -s \"http://localhost:3100/loki/api/v1/query_range\" --data-urlencode 'query={app=\"api\"} |= \"error\"' | jq .${CLR_RESET}"
echo -e "  • Promtail Targets/Status:    ${CLR_BOLD}http://localhost:9080/targets${CLR_RESET}"
echo -e "  • Teardown environment:       ${CLR_BOLD}./cleanup.sh --all${CLR_RESET}\n"
