#!/usr/bin/env bash
# ==============================================================================
# test_synthetic_monitoring.sh - Automated Assertion Suite for Synthetic Probing
# ==============================================================================
# Verifies:
#   1. Health of Target App, Playwright Agent, Prometheus & Grafana
#   2. Baseline synthetic journey execution (all 5 steps passing)
#   3. Artificial latency degradation detection in step metrics
#   4. Intentional failure simulation, diagnostic screenshot capture & alerting
#   5. Automatic recovery verification
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

APP_URL="http://localhost:8080"
AGENT_URL="http://localhost:9115"
PROM_URL="http://localhost:9090"
GRAFANA_URL="http://localhost:3000"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCREENSHOTS_DIR="${SCRIPT_DIR}/screenshots"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_pass() {
    local test_name="$1"
    local message="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${CLR_BOLD}${test_name}${CLR_RESET}: ${message}"
}

record_fail() {
    local test_name="$1"
    local message="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${CLR_BOLD}${test_name}${CLR_RESET}: ${message}"
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🎭 Playwright Synthetic Journey Monitoring - Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Health Probes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking Service Endpoints...${CLR_RESET}"

if curl -s -f "${APP_URL}/healthz" >/dev/null; then
    record_pass "Target App Health" "CloudStore web app is responsive at ${APP_URL}"
else
    record_fail "Target App Health" "Target App unreachable at ${APP_URL}"
fi

if curl -s -f "${AGENT_URL}/healthz" >/dev/null; then
    record_pass "Synthetic Agent Health" "Playwright daemon is online at ${AGENT_URL}"
else
    record_fail "Synthetic Agent Health" "Playwright daemon unreachable at ${AGENT_URL}"
fi

if curl -s -f "${PROM_URL}/-/healthy" >/dev/null; then
    record_pass "Prometheus Health" "Prometheus TSDB is healthy at ${PROM_URL}"
else
    record_fail "Prometheus Health" "Prometheus unreachable at ${PROM_URL}"
fi

if curl -s -f "${GRAFANA_URL}/api/health" >/dev/null; then
    record_pass "Grafana Health" "Grafana dashboard is healthy at ${GRAFANA_URL}"
else
    record_fail "Grafana Health" "Grafana unreachable at ${GRAFANA_URL}"
fi

# ------------------------------------------------------------------------------
# 2. Baseline Synthetic Journey Run
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Executing Baseline Synthetic Checkout Journey...${CLR_RESET}"

RUN_RES=$(curl -s -X POST "${AGENT_URL}/run" 2>/dev/null || echo "{}")
IS_SUCCESS=$(echo "$RUN_RES" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('success', False))" 2>/dev/null || echo "False")
STEPS_COUNT=$(echo "$RUN_RES" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('steps', {})))" 2>/dev/null || echo "0")
TOTAL_TIME=$(echo "$RUN_RES" | python3 -c "import sys, json; data=json.load(sys.stdin); print(f\"{data.get('total_duration_seconds', 0.0):.2f}\")" 2>/dev/null || echo "0")

if [ "$IS_SUCCESS" = "True" ] && [ "$STEPS_COUNT" -ge 5 ]; then
    record_pass "Baseline Journey" "Completed 5/5 steps (Catalog, Login, Cart, Checkout, Confirm) in ${TOTAL_TIME}s"
else
    record_fail "Baseline Journey" "Journey failed or incomplete steps (success: $IS_SUCCESS, steps: $STEPS_COUNT)"
fi

echo "  Waiting for Prometheus scrape (3s)..."
sleep 3

PROM_UP=$(curl -s -G "${PROM_URL}/api/v1/query" --data-urlencode 'query=synthetic_journey_up{journey="checkout_flow"}' 2>/dev/null || echo "{}")
UP_VAL=$(echo "$PROM_UP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
res = data.get('data', {}).get('result', [])
print(res[0]['value'][1] if res else '0')
" 2>/dev/null || echo "0")

if [ "$UP_VAL" = "1" ]; then
    record_pass "Metric 'synthetic_journey_up'" "Prometheus recorded healthy metric value: 1"
else
    record_fail "Metric 'synthetic_journey_up'" "Prometheus value is '$UP_VAL' (expected '1')"
fi

# ------------------------------------------------------------------------------
# 3. Latency Degradation Chaos Simulation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Injecting Latency Chaos (2.5s delay on checkout)...${CLR_RESET}"

curl -s -X POST "${APP_URL}/api/chaos/latency?delay=2.5" >/dev/null

SLOW_RUN=$(curl -s -X POST "${AGENT_URL}/run" 2>/dev/null || echo "{}")
SLOW_STEP_TIME=$(echo "$SLOW_RUN" | python3 -c "
import sys, json
data = json.load(sys.stdin)
steps = data.get('steps', {})
print(f\"{steps.get('submit_order', 0.0):.2f}\")
" 2>/dev/null || echo "0.0")

if (( $(echo "$SLOW_STEP_TIME >= 2.0" | bc -l) )); then
    record_pass "Latency Detection" "Playwright accurately measured degraded step duration: ${SLOW_STEP_TIME}s (>= 2.0s threshold)"
else
    record_fail "Latency Detection" "Measured step duration ${SLOW_STEP_TIME}s was below expected 2.0s"
fi

# Reset latency
curl -s -X POST "${APP_URL}/api/chaos/reset" >/dev/null

# ------------------------------------------------------------------------------
# 4. Failure Chaos Simulation & Screenshot Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Injecting Failure Chaos (HTTP 500 on checkout) & Testing Screenshot Capture...${CLR_RESET}"

# Clear previous screenshots
rm -f "${SCREENSHOTS_DIR}"/failure_*.png 2>/dev/null || true

curl -s -X POST "${APP_URL}/api/chaos/fail-checkout" >/dev/null

FAIL_RUN=$(curl -s -X POST "${AGENT_URL}/run" 2>/dev/null || echo "{}")
FAIL_SUCCESS=$(echo "$FAIL_RUN" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('success', True))" 2>/dev/null || echo "True")
FAILED_STEP=$(echo "$FAIL_RUN" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('failed_step', 'none'))" 2>/dev/null || echo "none")

if [ "$FAIL_SUCCESS" = "False" ] && [ "$FAILED_STEP" = "submit_order" ]; then
    record_pass "Failure Detection" "Synthetic agent correctly detected error on step '${FAILED_STEP}'"
else
    record_fail "Failure Detection" "Expected failure on submit_order, got: success=$FAIL_SUCCESS, step=$FAILED_STEP"
fi

# Check failure screenshot
SCREENSHOT_COUNT=$(find "$SCREENSHOTS_DIR" -type f -name "failure_*.png" | wc -l | tr -d ' ')
if [ "$SCREENSHOT_COUNT" -ge 1 ]; then
    LATEST_SCREENSHOT=$(find "$SCREENSHOTS_DIR" -type f -name "failure_*.png" | head -n 1)
    FILE_SIZE=$(wc -c < "$LATEST_SCREENSHOT" | tr -d ' ')
    if [ "$FILE_SIZE" -gt 1000 ]; then
        record_pass "Screenshot Capture" "Saved high-res diagnostic screenshot (${FILE_SIZE} bytes): $(basename "$LATEST_SCREENSHOT")"
    else
        record_fail "Screenshot Capture" "Screenshot file size too small (${FILE_SIZE} bytes)"
    fi
else
    record_fail "Screenshot Capture" "No screenshot file found in $SCREENSHOTS_DIR"
fi

echo "  Waiting for Prometheus alert evaluation (4s)..."
sleep 4

PROM_ALERT_UP=$(curl -s -G "${PROM_URL}/api/v1/query" --data-urlencode 'query=synthetic_journey_up{journey="checkout_flow"}' 2>/dev/null || echo "{}")
ALERT_UP_VAL=$(echo "$PROM_ALERT_UP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
res = data.get('data', {}).get('result', [])
print(res[0]['value'][1] if res else '1')
" 2>/dev/null || echo "1")

if [ "$ALERT_UP_VAL" = "0" ]; then
    record_pass "Metric Failure Drop" "Metric 'synthetic_journey_up' dropped to 0"
else
    record_fail "Metric Failure Drop" "Expected 0, got $ALERT_UP_VAL"
fi

PROM_RULES=$(curl -s "${PROM_URL}/api/v1/rules" 2>/dev/null || echo "{}")
HAS_RULE=$(echo "$PROM_RULES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
groups = data.get('data', {}).get('groups', [])
found = any(any(r.get('name') == 'SyntheticJourneyBroken' for r in g.get('rules', [])) for g in groups)
print(found)
" 2>/dev/null || echo "False")

if [ "$HAS_RULE" = "True" ]; then
    record_pass "Prometheus Alert Rule" "Alert rule 'SyntheticJourneyBroken' loaded in Prometheus TSDB"
else
    record_fail "Prometheus Alert Rule" "Alert rule 'SyntheticJourneyBroken' not found"
fi

# ------------------------------------------------------------------------------
# 5. Recovery Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Resetting Chaos & Testing Self-Healing Recovery...${CLR_RESET}"

curl -s -X POST "${APP_URL}/api/chaos/reset" >/dev/null

RECOVERY_RUN=$(curl -s -X POST "${AGENT_URL}/run" 2>/dev/null || echo "{}")
RECOVERY_SUCCESS=$(echo "$RECOVERY_RUN" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('success', False))" 2>/dev/null || echo "False")

if [ "$RECOVERY_SUCCESS" = "True" ]; then
    record_pass "System Recovery" "Journey restored to 100% operational health"
else
    record_fail "System Recovery" "Journey failed to recover after chaos reset"
fi

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  📊 Synthetic Monitoring Test Summary"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  Total Test Assertions: ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  Passed Assertions:     ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
if [ "$FAILED_TESTS" -gt 0 ]; then
    echo -e "  Failed Assertions:     ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
else
    echo -e "  Failed Assertions:     ${CLR_GREEN}${CLR_BOLD}0${CLR_RESET}"
fi

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✅ SUCCESS: Synthetic User Journey Monitoring is operating perfectly!${CLR_RESET}"
    echo -e "🔗 CloudStore Target App:  ${CLR_CYAN}${APP_URL}${CLR_RESET}"
    echo -e "🔗 Playwright Exporter:    ${CLR_CYAN}${AGENT_URL}/metrics${CLR_RESET}"
    echo -e "🔗 Prometheus Web Console: ${CLR_CYAN}${PROM_URL}${CLR_RESET}"
    echo -e "🔗 Grafana Dashboard:      ${CLR_CYAN}${GRAFANA_URL}/d/synthetic-user-journeys${CLR_RESET} (admin/admin)\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ FAILURE: ${FAILED_TESTS} assertions failed.${CLR_RESET}\n"
    exit 1
fi
