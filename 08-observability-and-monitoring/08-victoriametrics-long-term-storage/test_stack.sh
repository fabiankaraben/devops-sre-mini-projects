#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Runner for VictoriaMetrics LTS Stack
# ==============================================================================
# 1. Verifies Docker engine, Compose, and Python 3 prerequisites.
# 2. Builds container images and starts the VictoriaMetrics + Prometheus stack.
# 3. Awaits healthcheck readiness across all 3 services.
# 4. Ingests 1,000,000 data points and benchmarks ingestion & query performance.
# 5. Executes compare_storage_efficiency.sh to measure TSDB compression ratios.
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
echo "  🚀 VictoriaMetrics Long-Term Storage - Test Runner"
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

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is not installed."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python environment: $(python3 --version)"

# ------------------------------------------------------------------------------
# 2. Build Container Images
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Building Service Container Images...${CLR_RESET}"
$COMPOSE_CMD build
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container images built successfully."

# ------------------------------------------------------------------------------
# 3. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Starting VictoriaMetrics, Prometheus & Exporter Stack...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container healthcheck readiness..."
MAX_RETRIES=35
RETRY_COUNT=0
ALL_HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    VM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' victoriametrics-lts 2>/dev/null || echo '"starting"')"
    PROM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' prometheus-lts 2>/dev/null || echo '"starting"')"
    MOCK_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' mock-exporter-lts 2>/dev/null || echo '"starting"')"

    if [[ "$VM_STATUS" == '"healthy"' ]] && \
       [[ "$PROM_STATUS" == '"healthy"' ]] && \
       [[ "$MOCK_STATUS" == '"healthy"' ]]; then
        ALL_HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$ALL_HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All 3 containers (VictoriaMetrics, Prometheus, Mock Exporter) are healthy."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Stack failed to become healthy within timeout."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Ingest 1,000,000 Points & Compare Storage Efficiency
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Ingestion Benchmark & Storage Comparison...${CLR_RESET}"
python3 benchmark_metrics_ingestion.py --points 1000000 --series 1000

./compare_storage_efficiency.sh

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All VictoriaMetrics Tests & Benchmarks Completed Successfully!${CLR_RESET}"
echo -e "🔗 VictoriaMetrics vmui: ${CLR_CYAN}http://localhost:8428/vmui${CLR_RESET}"
echo -e "🔗 Prometheus Web UI:    ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
echo -e "🔗 Mock Exporter:        ${CLR_CYAN}http://localhost:8080/metrics${CLR_RESET}"
echo -e "\nTo clean up all resources, execute:"
echo -e "  ${CLR_BOLD}./cleanup.sh --purge-images${CLR_RESET}\n"
