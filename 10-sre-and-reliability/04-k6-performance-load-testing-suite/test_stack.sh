#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Automated End-to-End Test Suite for Mini-Project 10-04
# ==============================================================================
# Validates k6 Distributed Performance & Stress Testing Suite:
# 1. Validates system dependencies (Docker, Python 3, curl).
# 2. Builds and starts Docker Compose stack (Target API, InfluxDB, Grafana).
# 3. Validates Target API functionality (Catalog, Orders, Health).
# 4. Executes k6 Smoke Test and asserts passing thresholds (Exit Code 0).
# 5. Executes k6 Load Test with InfluxDB streaming and asserts SLOs pass.
# 6. Validates InfluxDB metric ingestion and Grafana dashboard provisioning.
# 7. Injects latency/error faults and asserts k6 CI/CD non-zero exit code failure.
# 8. Clears faults and executes k6 Spike Test.
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

API_URL="http://localhost:8080"
INFLUX_URL="http://localhost:8086"
GRAFANA_URL="http://localhost:3000"

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

log_header "🧪 STARTING k6 PERFORMANCE & STRESS TESTING TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/8] Checking system dependencies..."
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
log_step "[Step 1/8] Building and starting Docker Compose stack..."
$COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
$COMPOSE_CMD up -d --build >/dev/null 2>&1
assert_test "Docker Compose stack started" $?

log_step "Waiting for Target API, InfluxDB, and Grafana to be healthy..."
MAX_WAIT=35
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "$API_URL/health" >/dev/null 2>&1 && \
       curl -sf "$INFLUX_URL/ping" >/dev/null 2>&1 && \
       curl -sf "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
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
assert_test "All 3 services (Target API, InfluxDB, Grafana) are healthy" 0

# ------------------------------------------------------------------------------
# STEP 2: Validate Target API Endpoints
# ------------------------------------------------------------------------------
log_step "[Step 2/8] Validating target API functionality..."
HEALTH_RESP=$(curl -s "$API_URL/health")
if echo "$HEALTH_RESP" | grep -q '"status": "healthy"'; then
    assert_test "Target API /health returns healthy status" 0
else
    assert_test "Target API /health returns healthy status" 1
fi

CATALOG_RESP=$(curl -s "$API_URL/api/v1/products?limit=5")
if echo "$CATALOG_RESP" | grep -q '"total_items"'; then
    assert_test "Target API /api/v1/products returns product catalog" 0
else
    assert_test "Target API /api/v1/products returns product catalog" 1
fi

ORDER_RESP=$(curl -s -X POST "$API_URL/api/v1/orders" -H "Content-Type: application/json" -d '{"user_id":"test_u1","items":[{"product_id":1,"quantity":2}]}')
if echo "$ORDER_RESP" | grep -q '"status": "CONFIRMED"'; then
    assert_test "Target API /api/v1/orders creates confirmed orders" 0
else
    assert_test "Target API /api/v1/orders creates confirmed orders" 1
fi

# ------------------------------------------------------------------------------
# STEP 3: Execute k6 Smoke Test
# ------------------------------------------------------------------------------
log_step "[Step 3/8] Executing k6 Smoke Test (scripts/smoke_test.js)..."
./run_performance_suite.sh --scenario=smoke
assert_test "k6 Smoke Test passed all threshold assertions (Exit Code: 0)" $?

# ------------------------------------------------------------------------------
# STEP 4: Execute k6 Load Test with InfluxDB Telemetry
# ------------------------------------------------------------------------------
log_step "[Step 4/8] Executing k6 Load Test (scripts/load_test.js) with InfluxDB export..."
./run_performance_suite.sh --scenario=load
assert_test "k6 Load Test passed all SLO percentile thresholds (Exit Code: 0)" $?

# ------------------------------------------------------------------------------
# STEP 5: Validate InfluxDB Metric Ingestion
# ------------------------------------------------------------------------------
log_step "[Step 5/8] Verifying InfluxDB telemetry data ingestion..."
INFLUX_CHECK=$(curl -s -G "$INFLUX_URL/query" --data-urlencode "db=k6" --data-urlencode "q=SHOW MEASUREMENTS")
if echo "$INFLUX_CHECK" | grep -q "http_req_duration"; then
    assert_test "InfluxDB successfully recorded k6 telemetry measurements" 0
else
    assert_test "InfluxDB successfully recorded k6 telemetry measurements" 1
fi

# ------------------------------------------------------------------------------
# STEP 6: Validate Grafana Dashboard Provisioning
# ------------------------------------------------------------------------------
log_step "[Step 6/8] Verifying Grafana SRE Dashboard provisioning..."
GRAFANA_DASH=$(curl -s "$GRAFANA_URL/api/dashboards/uid/k6-sre-perf-dashboard")
if echo "$GRAFANA_DASH" | grep -q "k6-sre-perf-dashboard" && echo "$GRAFANA_DASH" | grep -q "InfluxDB-k6"; then
    assert_test "Grafana auto-provisioned SRE performance dashboard successfully" 0
else
    assert_test "Grafana auto-provisioned SRE performance dashboard successfully" 1
fi

# ------------------------------------------------------------------------------
# STEP 7: Test CI/CD Threshold Failure Detection (Fault Injection)
# ------------------------------------------------------------------------------
log_step "[Step 7/8] Testing CI/CD Threshold Breach Quality Gate..."
# Inject 300ms latency and 30% errors
curl -s -X POST "$API_URL/fault/latency?delay_ms=300" >/dev/null
curl -s -X POST "$API_URL/fault/errors?rate=0.30" >/dev/null

log_step "Running smoke test during active degradation (Expecting non-zero exit code)..."
set +e
./run_performance_suite.sh --scenario=smoke >/dev/null 2>&1
BREACH_EXIT_CODE=$?
set -e

if [ "$BREACH_EXIT_CODE" -ne 0 ]; then
    assert_test "k6 returned non-zero exit code ($BREACH_EXIT_CODE) on SLO threshold breach" 0
else
    assert_test "k6 returned non-zero exit code ($BREACH_EXIT_CODE) on SLO threshold breach" 1
fi

# Clear faults
curl -s -X POST "$API_URL/fault/reset" >/dev/null

# ------------------------------------------------------------------------------
# STEP 8: Execute k6 Spike Test
# ------------------------------------------------------------------------------
log_step "[Step 8/8] Executing k6 Spike Test (scripts/spike_test.js)..."
./run_performance_suite.sh --scenario=spike
assert_test "k6 Spike Test passed all recovery threshold assertions" $?

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
