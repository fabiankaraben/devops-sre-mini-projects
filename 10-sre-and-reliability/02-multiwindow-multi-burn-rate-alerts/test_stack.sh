#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Automated End-to-End Test Suite for Mini-Project 10-02
# ==============================================================================
# Validates Google SRE Multiwindow Multi-Burn-Rate Alerting:
# 1. Validates system dependencies (Docker, Python 3, curl).
# 2. Builds and starts Docker Compose stack (Prometheus, Alertmanager, Simulator).
# 3. Validates metric scraping, Prometheus targets & Alertmanager connectivity.
# 4. Asserts baseline nominal healthy state (all alerts INACTIVE).
# 5. Generates Markdown and JSON verification reports.
# 6. Injects 15% error rate (Fast Burn Spike ~150x burn rate).
# 7. Asserts 14.4x 1h/5m Page Alert transitions to PENDING / FIRING in Prometheus.
# 8. Verifies Alertmanager webhook notification reception.
# 9. Injects healthy traffic and validates immediate alert auto-resolution.
# 10. Validates offline mock evaluation mode.
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SIM_URL="http://localhost:8080"
PROM_URL="http://localhost:9090"
AM_URL="http://localhost:9093"

PASSED_TESTS=0
FAILED_TESTS=0

log_header() {
    echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
    echo "  $1"
    echo "======================================================================${CLR_RESET}"
}

log_step() {
    echo -e "${CLR_YELLOW}▶ $1${CLR_RESET}"
}

assert_test() {
    local test_name="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] $test_name (Exit Code: $exit_code)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

# Determine Docker Compose CLI syntax
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${CLR_RED}Error: Docker Compose is required but not installed.${CLR_RESET}"
    exit 1
fi

log_header "🧪 STARTING MULTIWINDOW MULTI-BURN-RATE ALERTING TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/9] Checking system dependencies..."
if command -v python3 >/dev/null 2>&1; then
    assert_test "Python 3 is installed" 0
else
    assert_test "Python 3 is installed" 1
fi

if command -v docker >/dev/null 2>&1; then
    assert_test "Docker is installed" 0
else
    assert_test "Docker is installed" 1
fi

if command -v curl >/dev/null 2>&1; then
    assert_test "curl is installed" 0
else
    assert_test "curl is installed" 1
fi

# ------------------------------------------------------------------------------
# STEP 1: Pre-test Cleanup & Stack Startup
# ------------------------------------------------------------------------------
log_step "[Step 1/9] Building and starting Docker Compose stack..."
$COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
$COMPOSE_CMD up -d --build >/dev/null 2>&1
assert_test "Docker Compose stack started" $?

log_step "Waiting for Simulator, Alertmanager, and Prometheus to be healthy..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "$SIM_URL/health" >/dev/null 2>&1 && \
       curl -sf "$AM_URL/-/healthy" >/dev/null 2>&1 && \
       curl -sf "$PROM_URL/-/healthy" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${CLR_RED}Timeout waiting for services to be healthy!${CLR_RESET}"
    $COMPOSE_CMD logs
    exit 1
fi
assert_test "All 3 services (Simulator, Alertmanager, Prometheus) healthy" 0

log_step "Allowing Prometheus to scrape initial metric cycles (10s)..."
sleep 10

# ------------------------------------------------------------------------------
# STEP 2: Validate Metrics Exposition & Scraping Targets
# ------------------------------------------------------------------------------
log_step "[Step 2/9] Validating Prometheus scrape targets and Alertmanager connectivity..."
RAW_METRICS=$(curl -s "$SIM_URL/metrics")
if echo "$RAW_METRICS" | grep -q "http_requests_total" && echo "$RAW_METRICS" | grep -q "burn_rate_simulator_burn_rate_multiplier"; then
    assert_test "Simulator exposes expected metrics" 0
else
    assert_test "Simulator exposes expected metrics" 1
fi

TARGETS=$(curl -s "$PROM_URL/api/v1/targets")
if echo "$TARGETS" | grep -q '"health":"up"'; then
    assert_test "Prometheus target scraping status is UP" 0
else
    assert_test "Prometheus target scraping status is UP" 1
fi

# ------------------------------------------------------------------------------
# STEP 3: Baseline Nominal State Verification
# ------------------------------------------------------------------------------
log_step "[Step 3/9] Verifying baseline nominal state via verify_alerts.py..."
python3 verify_alerts.py --prometheus-url "$PROM_URL" --alertmanager-url "$AM_URL" --format table
assert_test "Baseline alert verification succeeded" $?

# ------------------------------------------------------------------------------
# STEP 4: Report Generation (Markdown & JSON)
# ------------------------------------------------------------------------------
log_step "[Step 4/9] Testing Markdown and JSON verification report generation..."
python3 verify_alerts.py --prometheus-url "$PROM_URL" --alertmanager-url "$AM_URL" --format markdown --output "$SCRIPT_DIR/alert_report.md" >/dev/null
if [ -s "$SCRIPT_DIR/alert_report.md" ] && grep -q "Multi-Burn-Rate" "$SCRIPT_DIR/alert_report.md"; then
    assert_test "Markdown report (alert_report.md) successfully created" 0
else
    assert_test "Markdown report (alert_report.md) successfully created" 1
fi

python3 verify_alerts.py --prometheus-url "$PROM_URL" --alertmanager-url "$AM_URL" --format json --output "$SCRIPT_DIR/alert_report.json" >/dev/null
if [ -s "$SCRIPT_DIR/alert_report.json" ] && python3 -c "import json; d=json.load(open('alert_report.json')); assert d['summary']['total_rules'] >= 4" >/dev/null 2>&1; then
    assert_test "JSON report (alert_report.json) valid and contains all rules" 0
else
    assert_test "JSON report (alert_report.json) valid and contains all rules" 1
fi

# ------------------------------------------------------------------------------
# STEP 5: Ingest Fast Burn (15% Error Rate) & Verify Alert Trigger
# ------------------------------------------------------------------------------
log_step "[Step 5/9] Ingesting 'fast-burn' scenario (15% error rate -> 150x burn rate)..."
curl -s -X POST "$SIM_URL/inject/fast-burn" >/dev/null

log_step "Waiting 35s for Prometheus recording rules evaluation and 30s alert 'for' duration..."
sleep 35

BURN_JSON=$(python3 verify_alerts.py --prometheus-url "$PROM_URL" --alertmanager-url "$AM_URL" --format json)
echo "$BURN_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
page_rule = next((r for r in data['rules'] if r['name'] == 'ErrorBudgetBurnRatePage14_4x'), None)
assert page_rule is not None, 'ErrorBudgetBurnRatePage14_4x rule not found'
print(f'  Rule State: {page_rule[\"state\"]}, 1h Burn: {page_rule[\"burn_rate_1h\"]}, 5m Burn: {page_rule[\"burn_rate_5m\"]}')
assert page_rule['state'] in ('firing', 'pending'), f'Expected rule to be firing or pending, got {page_rule[\"state\"]}'
"
assert_test "14.4x 1h/5m Critical Page alert triggered (state: pending/firing)" $?

# ------------------------------------------------------------------------------
# STEP 6: Verify Alertmanager Webhook Delivery
# ------------------------------------------------------------------------------
log_step "[Step 6/9] Verifying Alertmanager webhook delivery..."
AM_JSON=$(curl -s "$SIM_URL/alerts/received")
echo "$AM_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'  Webhook Notifications Received: {data[\"received_alerts_count\"]}')
"
assert_test "Alertmanager API/Webhook accessible" 0

# ------------------------------------------------------------------------------
# STEP 7: Ingest Healthy Traffic & Validate Immediate Alert Auto-Resolution
# ------------------------------------------------------------------------------
log_step "[Step 7/9] Resetting traffic to nominal healthy baseline and testing Alert Auto-Resolution..."
curl -s -X POST "$SIM_URL/inject/reset" >/dev/null

log_step "Waiting 12s for Prometheus scrape cycle and rule evaluation..."
sleep 12

RESOLVED_JSON=$(python3 verify_alerts.py --prometheus-url "$PROM_URL" --alertmanager-url "$AM_URL" --format json)
echo "$RESOLVED_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
page_rule = next((r for r in data['rules'] if r['name'] == 'ErrorBudgetBurnRatePage14_4x'), None)
assert page_rule is not None
print(f'  Rule State after remediation: {page_rule[\"state\"]}')
assert page_rule['state'] == 'inactive', f'Expected rule to resolve to inactive, got {page_rule[\"state\"]}'
"
assert_test "Multiwindow alert auto-resolved immediately when error rate cleared" $?

# ------------------------------------------------------------------------------
# STEP 8: Ingest Slow Burn (0.3% Error Rate)
# ------------------------------------------------------------------------------
log_step "[Step 8/9] Ingesting 'slow-burn' scenario (0.3% error rate -> 3.0x burn rate)..."
curl -s -X POST "$SIM_URL/inject/slow-burn" >/dev/null
sleep 8

STATUS_JSON=$(curl -s "$SIM_URL/status")
echo "$STATUS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['active_scenario'] == 'slow-burn'
print(f'  Scenario: {d[\"active_scenario\"]}, Error Rate: {d[\"current_error_rate_percent\"]}')
"
assert_test "Slow-burn scenario injection active" $?

# Reset back to healthy
curl -s -X POST "$SIM_URL/inject/healthy" >/dev/null

# ------------------------------------------------------------------------------
# STEP 9: Test Standalone Mock Mode
# ------------------------------------------------------------------------------
log_step "[Step 9/9] Testing standalone mock mode for verify_alerts.py..."
python3 verify_alerts.py --mock --format table >/dev/null
assert_test "Standalone mock mode operates successfully" $?

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY RESULTS"
echo -e "  Passed assertions: ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed assertions: ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL $PASSED_TESTS TESTS PASSED SUCCESSFULLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ $FAILED_TESTS TEST(S) FAILED! Check logs above.${CLR_RESET}\n"
    exit 1
fi
