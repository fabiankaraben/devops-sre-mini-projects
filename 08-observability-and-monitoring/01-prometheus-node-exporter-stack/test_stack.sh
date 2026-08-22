#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - End-to-End Automated Test Runner for Prometheus Stack
# ==============================================================================
# 1. Validates Prometheus YAML configuration and rule files using promtool.
# 2. Deploys the Docker Compose stack (Prometheus + Node Exporter).
# 3. Awaits healthcheck readiness for all containers.
# 4. Executes the Python PromQL metrics validation test suite.
# 5. Tests Prometheus zero-downtime runtime configuration hot-reload (/-/reload).
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
echo "  🔭 Prometheus & Node Exporter Monitoring Stack - Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Check Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites...${CLR_RESET}"

# Check Docker engine
if ! command -v docker >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker is not installed or not in PATH."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running. Please start OrbStack or Docker Desktop."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker engine is running."

# Determine Docker Compose CLI syntax
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Neither 'docker compose' nor 'docker-compose' found."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose command: ${CLR_BOLD}${COMPOSE_CMD}${CLR_RESET}"

# Check Python 3
if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is not installed or not in PATH."
    exit 1
fi
PYTHON_VER="$(python3 --version)"
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python environment: ${PYTHON_VER}"

# ------------------------------------------------------------------------------
# 2. Syntax Validation with promtool
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building image & Validating Prometheus Config & Rules with promtool...${CLR_RESET}"

echo "  Building Prometheus container image..."
$COMPOSE_CMD build prometheus >/dev/null

echo "  Checking prometheus.yml syntax..."
docker run --rm --entrypoint promtool prometheus-custom-stack:v2.54.1 check config /etc/prometheus/prometheus.yml >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] prometheus.yml syntax and rule references are valid."

echo "  Checking rules/node_rules.yml syntax..."
docker run --rm --entrypoint promtool prometheus-custom-stack:v2.54.1 check rules /etc/prometheus/rules/node_rules.yml >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] rules/node_rules.yml recording and alert rules are valid."

# ------------------------------------------------------------------------------
# 3. Deploy Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Starting Prometheus & Node Exporter Stack...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container healthcheck readiness..."
MAX_RETRIES=30
RETRY_COUNT=0
HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    PROM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' prometheus-server 2>/dev/null || echo '"starting"')"
    NODE_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' node-exporter 2>/dev/null || echo '"starting"')"

    if [[ "$PROM_STATUS" == '"healthy"' ]] && [[ "$NODE_STATUS" == '"healthy"' ]]; then
        HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All containers are healthy and operational."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Timeout waiting for containers to become healthy."
    $COMPOSE_CMD ps
    exit 1
fi

# Allow Prometheus 5 seconds to complete initial scrapes
sleep 5

# ------------------------------------------------------------------------------
# 4. Run PromQL Validation Test Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Executing Python PromQL Validation Suite...${CLR_RESET}"
python3 "$SCRIPT_DIR/promql_validation.py" --url "http://localhost:9090" --verbose

# ------------------------------------------------------------------------------
# 5. Test Live Configuration Hot-Reloading
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Testing Prometheus Zero-Downtime Hot-Reload (/-/reload)...${CLR_RESET}"
RELOAD_STATUS="$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:9090/-/reload || echo "000")"

if [[ "$RELOAD_STATUS" == "200" ]]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] POST /-/reload returned HTTP 200 OK. Config reloaded successfully without restart."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] POST /-/reload returned HTTP ${RELOAD_STATUS}."
    exit 1
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✅ ALL TESTS COMPLETED SUCCESSFULLY!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Prometheus Web UI : ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
echo -e "  • Node Exporter API : ${CLR_CYAN}http://localhost:9100/metrics${CLR_RESET}"
echo -e "  • To teardown stack : ${CLR_YELLOW}./cleanup.sh${CLR_RESET}\n"
