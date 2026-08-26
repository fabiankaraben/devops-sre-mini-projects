#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Runner for OTel Collector Pipeline
# ==============================================================================
# 1. Verifies Docker engine, Compose, and Python 3 prerequisites.
# 2. Builds container images and starts the distributed telemetry pipeline.
# 3. Awaits healthcheck readiness across Jaeger, Collector, Prometheus & App.
# 4. Executes pipeline_health_check.sh to validate end-to-end metrics & traces.
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
echo "  🔭 OpenTelemetry Collector Telemetry Pipeline - Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running."
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

if ! command -v curl >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] curl is not installed."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] curl command available."

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is not installed."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python environment: $(python3 --version)"

# ------------------------------------------------------------------------------
# 2. Build Container Images
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Building Pipeline Container Images...${CLR_RESET}"
$COMPOSE_CMD build
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container images built successfully."

# ------------------------------------------------------------------------------
# 3. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Launching OTel Collector, Jaeger, Prometheus & App Stack...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container healthcheck readiness..."
MAX_RETRIES=40
RETRY_COUNT=0
ALL_HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    JAEGER_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' jaeger-pipeline 2>/dev/null || echo '"starting"')"
    COLLECTOR_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' otel-collector-pipeline 2>/dev/null || echo '"starting"')"
    PROM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' prometheus-pipeline 2>/dev/null || echo '"starting"')"
    APP_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' sample-app-pipeline 2>/dev/null || echo '"starting"')"

    if [[ "$JAEGER_STATUS" == '"healthy"' ]] && \
       [[ "$COLLECTOR_STATUS" == '"healthy"' ]] && \
       [[ "$PROM_STATUS" == '"healthy"' ]] && \
       [[ "$APP_STATUS" == '"healthy"' ]]; then
        ALL_HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$ALL_HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All 4 containers (Jaeger, OTel Collector, Prometheus, Sample App) are healthy."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Pipeline stack failed to reach healthy state within timeout."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Execute Pipeline Health Check Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Telemetry Pipeline Health Check...${CLR_RESET}"
./pipeline_health_check.sh

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All OpenTelemetry Collector Pipeline Tests Passed!${CLR_RESET}"
echo -e "🔗 Jaeger UI:        ${CLR_CYAN}http://localhost:16686${CLR_RESET}"
echo -e "🔗 Prometheus UI:    ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
echo -e "🔗 Sample App Docs:  ${CLR_CYAN}http://localhost:8080/docs${CLR_RESET}"
echo -e "🔗 Collector Health: ${CLR_CYAN}http://localhost:13133/${CLR_RESET}"
echo -e "\nTo clean up all resources, execute:"
echo -e "  ${CLR_BOLD}./cleanup.sh --purge-images${CLR_RESET}\n"
