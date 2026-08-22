#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Runner for Blackbox Probing Stack
# ==============================================================================
# 1. Validates Prometheus rules with promtool.
# 2. Builds container images and launches Docker Compose stack.
# 3. Awaits healthcheck readiness across Prometheus, Blackbox, and Mock Targets.
# 4. Executes validate_probes.py to verify multi-protocol probe assertions.
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
echo "  🔍 Prometheus Blackbox Exporter - Automated Test Runner"
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
# 2. Build Container Images & Validate Rules
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Building Container Images & Validating Rules...${CLR_RESET}"

echo "  Building container images..."
$COMPOSE_CMD build >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All container images built successfully."

echo "  Validating Prometheus probe rules with promtool..."
docker run --rm --entrypoint promtool mini-proj-08-05-prometheus:local check rules /etc/prometheus/rules/probe_rules.yml >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] probe_rules.yml validated with promtool."

# ------------------------------------------------------------------------------
# 3. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Starting Prometheus, Blackbox Exporter & Mock Targets...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container healthcheck readiness..."
MAX_RETRIES=25
RETRY_COUNT=0
HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    PROM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' prometheus-server 2>/dev/null || echo '"starting"')"
    BB_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' blackbox-exporter 2>/dev/null || echo '"starting"')"
    MOCK_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' mock-targets 2>/dev/null || echo '"starting"')"

    if [[ "$PROM_STATUS" == '"healthy"' ]] && \
       [[ "$BB_STATUS" == '"healthy"' ]] && \
       [[ "$MOCK_STATUS" == '"healthy"' ]]; then
        HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All 3 containers (Prometheus, Blackbox Exporter, Mock Targets) are healthy."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Timeout waiting for services to become healthy."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Execute Programmatic Probe Test Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Synthetic Probe Validation Suite...${CLR_RESET}"
python3 "$SCRIPT_DIR/validate_probes.py"

echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✅ BLACKBOX UPTIME PROBING STACK READY!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Prometheus Web UI     : ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
echo -e "  • Prometheus Targets    : ${CLR_CYAN}http://localhost:9090/targets${CLR_RESET}"
echo -e "  • Blackbox Exporter UI  : ${CLR_CYAN}http://localhost:9115${CLR_RESET}"
echo -e "  • Mock Targets API      : ${CLR_CYAN}http://localhost:8080/api/healthy${CLR_RESET}"
echo -e "  • Teardown stack        : ${CLR_YELLOW}./cleanup.sh${CLR_RESET}\n"
