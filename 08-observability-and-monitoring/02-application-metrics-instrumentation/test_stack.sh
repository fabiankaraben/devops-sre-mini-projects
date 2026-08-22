#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - End-to-End Automated Test Runner for RED & USE Stack
# ==============================================================================
# 1. Validates system dependencies and Prometheus rules syntax via promtool.
# 2. Builds container images and starts Docker Compose stack.
# 3. Awaits container healthcheck readiness.
# 4. Executes multi-scenario traffic simulation to seed metrics.
# 5. Runs Python PromQL metrics validation suite.
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
echo "  🚀 RED & USE Metrics Instrumentation - Automated Test Runner"
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

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is not installed."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python environment: $(python3 --version)"

# ------------------------------------------------------------------------------
# 2. Build Images & Validate Config
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building Container Images & Validating Rules...${CLR_RESET}"

$COMPOSE_CMD build >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container images built successfully."

# Promtool syntax validation
echo "  Checking prometheus.yml and rules/app_rules.yml with promtool..."
docker run --rm --entrypoint promtool mini-proj-08-02-prometheus:local check config /etc/prometheus/prometheus.yml >/dev/null
docker run --rm --entrypoint promtool mini-proj-08-02-prometheus:local check rules /etc/prometheus/rules/app_rules.yml >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Prometheus configuration and rule files validated."

# ------------------------------------------------------------------------------
# 3. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Starting Application & Prometheus Containers...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container readiness..."
MAX_RETRIES=20
RETRY_COUNT=0
HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    APP_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' instrumented-app 2>/dev/null || echo '"starting"')"
    PROM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' prometheus-app-monitor 2>/dev/null || echo '"starting"')"

    if [[ "$APP_STATUS" == '"healthy"' ]] && [[ "$PROM_STATUS" == '"healthy"' ]]; then
        HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All containers healthy and accepting requests."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Containers failed to reach healthy status."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Generate Synthetic Traffic (Seeding RED & USE Metrics)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Generating Synthetic Traffic (RED & USE Workload)...${CLR_RESET}"
python3 "$SCRIPT_DIR/traffic_simulator.py" --url "http://localhost:8000" --scenario "all" --duration 15 --concurrency 6

echo "  Waiting 4 seconds for Prometheus scrape ingestion..."
sleep 4

# ------------------------------------------------------------------------------
# 5. Run PromQL Validation Test Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Executing PromQL Metrics Validation Suite...${CLR_RESET}"
python3 "$SCRIPT_DIR/promql_validation.py" --url "http://localhost:9090" --verbose

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✅ E2E TEST RUN COMPLETED SUCCESSFULLY!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Web API Health    : ${CLR_CYAN}http://localhost:8000/healthz${CLR_RESET}"
echo -e "  • Raw Metrics API   : ${CLR_CYAN}http://localhost:8000/metrics${CLR_RESET}"
echo -e "  • Prometheus Web UI : ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
echo -e "  • Teardown stack    : ${CLR_YELLOW}./cleanup.sh${CLR_RESET}\n"
