#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Runner for Grafana DaC Stack
# ==============================================================================
# 1. Validates JSON dashboard models and YAML configuration files.
# 2. Builds container images and starts Docker Compose stack.
# 3. Awaits container healthcheck readiness across all 4 services.
# 4. Executes the Grafana REST API smoke test suite (dashboard_smoke_test.sh).
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
echo "  📈 Grafana Dashboards as Code - Automated Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Checking System Prerequisites...${CLR_RESET}"

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

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is not installed."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python environment: $(python3 --version)"

# ------------------------------------------------------------------------------
# 2. Validate JSON Models & Build Images
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Validating Dashboard JSON Models & Building Images...${CLR_RESET}"

echo "  Validating JSON syntax for provisioned dashboards..."
python3 -m json.tool "$SCRIPT_DIR/provisioning/dashboards/json/infra/node_exporter_overview.json" >/dev/null
python3 -m json.tool "$SCRIPT_DIR/provisioning/dashboards/json/apps/application_red_use.json" >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] JSON dashboard models are valid."

echo "  Building container images..."
$COMPOSE_CMD build >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All container images built successfully."

# ------------------------------------------------------------------------------
# 3. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Starting Grafana, Prometheus, Node Exporter & App Containers...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container healthcheck readiness..."
MAX_RETRIES=25
RETRY_COUNT=0
HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    GRAF_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' grafana-server 2>/dev/null || echo '"starting"')"
    PROM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' prometheus-server 2>/dev/null || echo '"starting"')"
    NODE_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' node-exporter 2>/dev/null || echo '"starting"')"
    APP_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' telemetry-app 2>/dev/null || echo '"starting"')"

    if [[ "$GRAF_STATUS" == '"healthy"' ]] && \
       [[ "$PROM_STATUS" == '"healthy"' ]] && \
       [[ "$NODE_STATUS" == '"healthy"' ]] && \
       [[ "$APP_STATUS" == '"healthy"' ]]; then
        HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All 4 services are healthy and operational."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Timeout waiting for services to become healthy."
    $COMPOSE_CMD ps
    exit 1
fi

# Allow 5s for initial metrics scrape & ingestion
sleep 5

# ------------------------------------------------------------------------------
# 4. Execute Smoke Test Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Grafana REST API Smoke Test Suite...${CLR_RESET}"
bash "$SCRIPT_DIR/dashboard_smoke_test.sh"

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✅ DASHBOARDS AS CODE STACK READY!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Grafana Web UI    : ${CLR_CYAN}http://localhost:3000${CLR_RESET} (Anonymous Admin Access Enabled)"
echo -e "  • Prometheus Web UI : ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
echo -e "  • Microservice API  : ${CLR_CYAN}http://localhost:8000/metrics${CLR_RESET}"
echo -e "  • Teardown stack    : ${CLR_YELLOW}./cleanup.sh${CLR_RESET}\n"
