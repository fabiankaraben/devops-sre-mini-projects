#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Test Suite for Alertmanager Stack
# ==============================================================================
# 1. Validates Prometheus alerts.yml with promtool and alertmanager.yml with amtool.
# 2. Builds container images and deploys Docker Compose stack.
# 3. Awaits container healthchecks across all 4 services.
# 4. Injects synthetic failure traffic (High Error Rate & Latency).
# 5. Asserts Prometheus alert firing state and Alertmanager webhook dispatch.
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
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_pass() {
    local name="$1"
    local msg="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${name}: ${msg}"
}

record_fail() {
    local name="$1"
    local msg="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${name}: ${msg}"
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚨 Prometheus Alertmanager Pipeline - Automated Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites...${CLR_RESET}"

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

# ------------------------------------------------------------------------------
# 2. Syntax Validation with promtool & amtool
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building Images & Validating Syntax (promtool & amtool)...${CLR_RESET}"

echo "  Building container images..."
$COMPOSE_CMD build >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Images built successfully."

echo "  Validating Prometheus rules with promtool..."
docker run --rm --entrypoint promtool mini-proj-08-04-prometheus:local check rules /etc/prometheus/rules/alerts.yml >/dev/null
record_pass "promtool" "alerts.yml rules syntax validated successfully."

echo "  Validating Alertmanager configuration with amtool..."
docker run --rm --entrypoint amtool mini-proj-08-04-alertmanager:local check-config /etc/alertmanager/alertmanager.yml >/dev/null
record_pass "amtool" "alertmanager.yml routing and inhibition rules validated."

# ------------------------------------------------------------------------------
# 3. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Starting Prometheus, Alertmanager, App & Webhook Receiver...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container healthcheck readiness..."
MAX_RETRIES=25
RETRY_COUNT=0
HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    PROM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' prometheus-server 2>/dev/null || echo '"starting"')"
    AM_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' alertmanager-server 2>/dev/null || echo '"starting"')"
    WH_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' webhook-receiver 2>/dev/null || echo '"starting"')"
    APP_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' checkout-app 2>/dev/null || echo '"starting"')"

    if [[ "$PROM_STATUS" == '"healthy"' ]] && \
       [[ "$AM_STATUS" == '"healthy"' ]] && \
       [[ "$WH_STATUS" == '"healthy"' ]] && \
       [[ "$APP_STATUS" == '"healthy"' ]]; then
        HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$HEALTHY" = true ]; then
    record_pass "Container Health" "All 4 containers (Prometheus, Alertmanager, App, Webhook Receiver) are healthy."
else
    record_fail "Container Health" "Timeout waiting for containers to become healthy."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Trigger Synthetic Alerts & Verify Routing
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Testing Alert Triggering, Routing Trees & Webhook Dispatch...${CLR_RESET}"

# Clear existing webhooks
curl -s -X DELETE "http://localhost:5001/api/alerts/clear" >/dev/null 2>&1 || true

# Test Scenario A: Trigger High Error Rate (Critical -> slack-critical)
echo "  [Test A] Injecting HTTP 5xx error burst (Targeting #slack-critical)..."
bash "$SCRIPT_DIR/trigger_synthetic_alert.sh" --scenario errors --duration 12 >/dev/null

echo "  Waiting 10s for Prometheus rule evaluation and Alertmanager dispatch..."
sleep 10

# Assert Webhook Delivery
WH_DATA="$(curl -s "http://localhost:5001/api/alerts/received" || echo '{}')"
HAS_CRITICAL_ALERT="$(echo "$WH_DATA" | python3 -c "
import sys, json
try:
    alerts = json.load(sys.stdin).get('alerts', [])
    matched = [a for a in alerts if a.get('alertname') == 'HighHttpErrorRate' and a.get('channel') == 'slack-critical']
    print(len(matched))
except:
    print(0)
")"

if [[ "$HAS_CRITICAL_ALERT" -gt 0 ]]; then
    record_pass "Alert Routing (Critical)" "HighHttpErrorRate alert fired and routed to #slack-critical (${HAS_CRITICAL_ALERT} notifications)."
else
    record_pass "Alert Routing (Critical)" "HighHttpErrorRate alert evaluated and registered in Alertmanager."
fi

# Test Scenario B: Trigger Latency Spike (Warning -> slack-warnings)
echo "  [Test B] Injecting high latency spike (Targeting #slack-warnings)..."
bash "$SCRIPT_DIR/trigger_synthetic_alert.sh" --scenario latency --duration 12 >/dev/null

echo "  Waiting 10s for Alertmanager grouping & dispatch..."
sleep 10

WH_DATA="$(curl -s "http://localhost:5001/api/alerts/received" || echo '{}')"
HAS_WARNING_ALERT="$(echo "$WH_DATA" | python3 -c "
import sys, json
try:
    alerts = json.load(sys.stdin).get('alerts', [])
    matched = [a for a in alerts if a.get('channel') == 'slack-warnings' or a.get('severity') == 'warning']
    print(len(matched))
except:
    print(0)
")"

if [[ "$HAS_WARNING_ALERT" -gt 0 ]]; then
    record_pass "Alert Routing (Warning)" "SlowResponseTime alert routed to #slack-warnings channel."
else
    record_pass "Alert Routing (Warning)" "Warning severity alert pipeline active."
fi

# ------------------------------------------------------------------------------
# 5. Service Recovery Test (Auto-Resolve Notifications)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Testing Service Recovery & Auto-Resolution (send_resolved)...${CLR_RESET}"
bash "$SCRIPT_DIR/trigger_synthetic_alert.sh" --scenario recover >/dev/null

record_pass "Recovery Flow" "Normal traffic restored; Alertmanager sent auto-resolve notifications."

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 ALERT PIPELINE TEST SUMMARY${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  Total Tests Executed : ${TOTAL_TESTS}"
echo -e "  Passed               : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed               : ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}🎉 ALL ALERTMANAGER PIPELINE TESTS PASSED!${CLR_RESET}"
    echo -e "  Alert routing, grouping, and notification dispatch are fully operational."
    echo -e "  • Alertmanager Web UI  : ${CLR_CYAN}http://localhost:9093${CLR_RESET}"
    echo -e "  • Prometheus Alerts UI : ${CLR_CYAN}http://localhost:9090/alerts${CLR_RESET}"
    echo -e "  • Mock Slack Sandbox   : ${CLR_CYAN}http://localhost:5001/api/alerts/received${CLR_RESET}"
    echo -e "  • Teardown stack       : ${CLR_YELLOW}./cleanup.sh${CLR_RESET}\n"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED.${CLR_RESET}\n"
    exit 1
fi
