#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - End-to-End Automated Test Suite for Mini-Project 10-01
# ==============================================================================
# Verifies SLI, SLO, and Error Budget Calculator functionality:
# 1. Validates system dependencies (Docker, Python 3, curl).
# 2. Builds and starts Docker Compose stack (Prometheus & Mock Metrics Exporter).
# 3. Validates metric scraping and Prometheus targets.
# 4. Evaluates Baseline Healthy scenario with slo_calculator.py.
# 5. Tests Markdown & JSON report generation.
# 6. Tests Prometheus Exporter format output.
# 7. Injects Minor Degradation and validates elevated burn rates.
# 8. Injects Major Outage and validates SLO breach detection & strict mode exit codes.
# 9. Injects Latency Spike and validates latency SLI degradation.
# 10. Validates standalone/mock offline calculation mode.
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

MOCK_URL="http://localhost:8080"
PROM_URL="http://localhost:9090"

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

log_header "🧪 STARTING SRE SLI/SLO & ERROR BUDGET CALCULATOR TEST SUITE"

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
log_step "[Step 1/9] Starting Docker Compose stack..."
$COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
$COMPOSE_CMD up -d --build >/dev/null 2>&1
assert_test "Docker compose services started" $?

log_step "Waiting for mock-service and Prometheus to be healthy..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "$MOCK_URL/health" >/dev/null 2>&1 && curl -sf "$PROM_URL/-/healthy" >/dev/null 2>&1; then
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
assert_test "Services are healthy and responding" 0

# Wait for Prometheus first scrape cycles
log_step "Allowing Prometheus to scrape initial metric cycles (10s)..."
sleep 10

# ------------------------------------------------------------------------------
# STEP 2: Validate Raw Metrics & Prometheus Targets
# ------------------------------------------------------------------------------
log_step "[Step 2/9] Validating metrics exposition & target scraping..."
RAW_METRICS=$(curl -s "$MOCK_URL/metrics")
if echo "$RAW_METRICS" | grep -q "http_requests_total" && echo "$RAW_METRICS" | grep -q "http_request_duration_seconds"; then
    assert_test "Mock metrics endpoint exposes expected Prometheus counters and histograms" 0
else
    assert_test "Mock metrics endpoint exposes expected Prometheus counters and histograms" 1
fi

TARGETS_RESP=$(curl -s "$PROM_URL/api/v1/targets")
if echo "$TARGETS_RESP" | grep -q '"health":"up"'; then
    assert_test "Prometheus target scraping status is UP" 0
else
    assert_test "Prometheus target scraping status is UP" 1
fi

# ------------------------------------------------------------------------------
# STEP 3: Test Baseline Healthy Scenario Calculation
# ------------------------------------------------------------------------------
log_step "[Step 3/9] Evaluating baseline healthy SLO metrics via slo_calculator.py..."
python3 slo_calculator.py --prometheus-url "$PROM_URL" --format table
assert_test "Baseline SLO calculation completed successfully" $?

# ------------------------------------------------------------------------------
# STEP 4: Test Report Generation (Markdown & JSON)
# ------------------------------------------------------------------------------
log_step "[Step 4/9] Testing Markdown and JSON report generation..."
python3 slo_calculator.py --prometheus-url "$PROM_URL" --format markdown --output "$SCRIPT_DIR/slo_report.md" >/dev/null
if [ -s "$SCRIPT_DIR/slo_report.md" ] && grep -q "SRE Reliability" "$SCRIPT_DIR/slo_report.md"; then
    assert_test "Markdown report (slo_report.md) successfully created and structured" 0
else
    assert_test "Markdown report (slo_report.md) successfully created and structured" 1
fi

python3 slo_calculator.py --prometheus-url "$PROM_URL" --format json --output "$SCRIPT_DIR/slo_report.json" >/dev/null
if [ -s "$SCRIPT_DIR/slo_report.json" ] && python3 -c "import json; d=json.load(open('slo_report.json')); assert d['summary']['total_slos'] >= 4" >/dev/null 2>&1; then
    assert_test "JSON report (slo_report.json) valid and contains all SLO definitions" 0
else
    assert_test "JSON report (slo_report.json) valid and contains all SLO definitions" 1
fi

# ------------------------------------------------------------------------------
# STEP 5: Test Prometheus Exporter Format Output
# ------------------------------------------------------------------------------
log_step "[Step 5/9] Testing Prometheus exporter output format..."
EXPORTER_OUT=$(python3 slo_calculator.py --prometheus-url "$PROM_URL" --format exporter)
if echo "$EXPORTER_OUT" | grep -q "sre_sli_ratio" && echo "$EXPORTER_OUT" | grep -q "sre_error_budget_remaining_ratio"; then
    assert_test "Prometheus exporter format successfully generated" 0
else
    assert_test "Prometheus exporter format successfully generated" 1
fi

# ------------------------------------------------------------------------------
# STEP 6: Ingest Minor Degradation Scenario
# ------------------------------------------------------------------------------
log_step "[Step 6/9] Ingesting 'minor_degradation' scenario..."
curl -s -X POST "$MOCK_URL/scenario/minor_degradation" >/dev/null
sleep 6

DEGRADED_JSON=$(python3 slo_calculator.py --prometheus-url "$PROM_URL" --window 1m --format json)
echo "$DEGRADED_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
checkout = next(s for s in data['slos'] if s['id'] == 'checkout_service_availability')
print(f'  Observed SLI: {checkout[\"sli_percent\"]:.3f}%, Burn Rate: {checkout[\"burn_rate\"]:.2f}x')
assert checkout['burn_rate'] > 1.0, f'Expected elevated burn rate > 1.0x, got {checkout[\"burn_rate\"]}'
"
assert_test "Minor degradation correctly detected with elevated burn rate" $?

# ------------------------------------------------------------------------------
# STEP 7: Ingest Major Outage Scenario & Test Strict Mode
# ------------------------------------------------------------------------------
log_step "[Step 7/9] Ingesting 'major_outage' scenario and testing --strict CI/CD exit code..."
curl -s -X POST "$MOCK_URL/scenario/major_outage" >/dev/null
sleep 6

# Strict mode should exit non-zero when SLO is breached
python3 slo_calculator.py --prometheus-url "$PROM_URL" --window 1m --strict >/dev/null 2>&1 && STRICT_EXIT=0 || STRICT_EXIT=$?
if [ "$STRICT_EXIT" -ne 0 ]; then
    assert_test "Strict mode correctly failed (returned exit code 1) on major outage SLO breach" 0
else
    assert_test "Strict mode correctly failed on major outage SLO breach" 1
fi

# ------------------------------------------------------------------------------
# STEP 8: Ingest Latency Spike Scenario
# ------------------------------------------------------------------------------
log_step "[Step 8/9] Ingesting 'latency_spike' scenario..."
curl -s -X POST "$MOCK_URL/scenario/latency_spike" >/dev/null
sleep 6

LATENCY_JSON=$(python3 slo_calculator.py --prometheus-url "$PROM_URL" --window 1m --format json)
echo "$LATENCY_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
catalog = next(s for s in data['slos'] if s['id'] == 'product_catalog_latency')
print(f'  Observed Latency SLI: {catalog[\"sli_percent\"]:.2f}% (Target: {catalog[\"target_percent\"]}%)')
assert catalog['sli_percent'] < catalog['target_percent'], 'Expected Latency SLI below target'
"
assert_test "Latency SLO degradation accurately flagged" $?

# Reset scenario back to healthy
curl -s -X POST "$MOCK_URL/scenario/healthy" >/dev/null

# ------------------------------------------------------------------------------
# STEP 9: Test Standalone Offline / Mock Mode
# ------------------------------------------------------------------------------
log_step "[Step 9/9] Testing standalone / offline mock mode without live Prometheus..."
python3 slo_calculator.py --mock --scenario healthy --format table >/dev/null
assert_test "Standalone offline mock mode evaluates successfully" $?

python3 slo_calculator.py --mock --scenario major_outage --strict >/dev/null 2>&1 && MOCK_STRICT=0 || MOCK_STRICT=$?
if [ "$MOCK_STRICT" -ne 0 ]; then
    assert_test "Offline mock mode strict assertion works as expected" 0
else
    assert_test "Offline mock mode strict assertion works as expected" 1
fi

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
