#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Automated End-to-End Test Suite for Mini-Project 10-06
# ==============================================================================
# Validates Circuit Breaker and Resilient Retry Engine:
# 1. System prerequisites check (Docker, Python 3, curl, pnpm).
# 2. Markdown documentation linting via markdownlint-cli.
# 3. Docker Compose build and healthy startup.
# 4. Concurrency test suite execution (circuit_breaker_test.py).
# 5. Live curl demonstration of state transitions and fallbacks.
# 6. Prometheus telemetry metric verification.
# 7. Verification of test report artifacts.
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

GATEWAY_URL="http://localhost:8080"
DOWNSTREAM_URL="http://localhost:8081"

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

log_header "🧪 STARTING CIRCUIT BREAKER & RESILIENCE ENGINE TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/6] Checking system dependencies and tools..."
if command -v python3 >/dev/null 2>&1; then
    assert_test "Python 3 is available" 0
else
    assert_test "Python 3 is available" 1
fi

if command -v docker >/dev/null 2>&1; then
    assert_test "Docker is available" 0
else
    assert_test "Docker is available" 1
fi

if command -v curl >/dev/null 2>&1; then
    assert_test "curl is available" 0
else
    assert_test "curl is available" 1
fi

if command -v pnpm >/dev/null 2>&1; then
    assert_test "pnpm is available" 0
else
    assert_test "pnpm is available" 1
fi

# ------------------------------------------------------------------------------
# STEP 1: Validate Documentation with Markdownlint
# ------------------------------------------------------------------------------
log_step "[Step 1/6] Linting README.md with markdownlint-cli..."
if command -v pnpm >/dev/null 2>&1; then
    pnpm dlx markdownlint-cli "$SCRIPT_DIR/README.md" >/dev/null 2>&1
    assert_test "README.md conforms strictly to markdownlint rules" $?
else
    echo -e "${CLR_YELLOW}Skipping markdownlint (pnpm not installed).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# STEP 2: Stack Build & Startup
# ------------------------------------------------------------------------------
log_step "[Step 2/6] Building and starting Docker Compose stack..."
$COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
$COMPOSE_CMD up -d --build >/dev/null 2>&1
assert_test "Docker Compose stack built and started successfully" $?

log_step "Waiting for Gateway and Downstream service to pass healthchecks..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "$GATEWAY_URL/health" >/dev/null 2>&1 && \
       curl -sf "$DOWNSTREAM_URL/health" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${CLR_RED}Timeout waiting for services to become healthy!${CLR_RESET}"
    $COMPOSE_CMD logs
    exit 1
fi
assert_test "Both Gateway (:8080) and Downstream (:8081) services are healthy" 0

# ------------------------------------------------------------------------------
# STEP 3: Execute Concurrency Test Suite
# ------------------------------------------------------------------------------
log_step "[Step 3/6] Running automated concurrency and state machine test suite..."
python3 "$SCRIPT_DIR/circuit_breaker_test.py" --gateway-url "$GATEWAY_URL" --downstream-url "$DOWNSTREAM_URL"
assert_test "Automated test suite (circuit_breaker_test.py) passed all 10 scenarios" $?

# ------------------------------------------------------------------------------
# STEP 4: Live Interactive Demonstration
# ------------------------------------------------------------------------------
log_step "[Step 4/6] Running live scenario demonstration via curl..."

# 4a: Reset to clean steady-state
curl -s -X POST "$DOWNSTREAM_URL/chaos/reset" >/dev/null
curl -s -X POST "$GATEWAY_URL/circuit/reset" -H "Content-Type: application/json" -d '{"reason":"Demo steady state"}' >/dev/null

STEADY_RESP=$(curl -s "$GATEWAY_URL/api/v1/orders/DEMO-101")
if echo "$STEADY_RESP" | grep -q '"is_fallback": false' && echo "$STEADY_RESP" | grep -q '"circuit_state": "CLOSED"'; then
    assert_test "Live Demonstration: Steady-state request succeeded in CLOSED state" 0
else
    assert_test "Live Demonstration: Steady-state request succeeded in CLOSED state" 1
fi

# 4b: Inject errors and trip circuit
curl -s -X POST "$DOWNSTREAM_URL/chaos/faults" -H "Content-Type: application/json" -d '{"mode":"error","error_code":500}' >/dev/null
# Send 5 failing calls
for i in {1..5}; do
    curl -s "$GATEWAY_URL/api/v1/orders/DEMO-FAIL-$i" >/dev/null
done

TRIP_STATE=$(curl -s "$GATEWAY_URL/circuit/state")
if echo "$TRIP_STATE" | grep -q '"state": "OPEN"'; then
    assert_test "Live Demonstration: 5 consecutive downstream errors tripped breaker to OPEN" 0
else
    assert_test "Live Demonstration: 5 consecutive downstream errors tripped breaker to OPEN" 1
fi

# 4c: Verify instant fail-fast fallback
FALLBACK_RESP=$(curl -s "$GATEWAY_URL/api/v1/orders/DEMO-FAST-FAIL")
if echo "$FALLBACK_RESP" | grep -q '"short_circuited": true' && echo "$FALLBACK_RESP" | grep -q '"is_fallback": true'; then
    assert_test "Live Demonstration: Instant fail-fast fallback returned without downstream call" 0
else
    assert_test "Live Demonstration: Instant fail-fast fallback returned without downstream call" 1
fi

# ------------------------------------------------------------------------------
# STEP 5: Validate Prometheus Metrics Endpoint
# ------------------------------------------------------------------------------
log_step "[Step 5/6] Validating Prometheus telemetry scrape endpoint..."
METRICS=$(curl -s "$GATEWAY_URL/metrics")
if echo "$METRICS" | grep -q "circuit_breaker_state" && echo "$METRICS" | grep -q "circuit_breaker_requests_total"; then
    assert_test "Gateway exposes valid Prometheus metrics (/metrics)" 0
else
    assert_test "Gateway exposes valid Prometheus metrics (/metrics)" 1
fi

# ------------------------------------------------------------------------------
# STEP 6: Validate Test Report Artifacts
# ------------------------------------------------------------------------------
log_step "[Step 6/6] Verifying test report artifacts generated within project dir..."
if [ -f "$SCRIPT_DIR/test_report.md" ] && [ -f "$SCRIPT_DIR/test_report.json" ]; then
    assert_test "Report files (test_report.md & test_report.json) exist" 0
else
    assert_test "Report files (test_report.md & test_report.json) exist" 1
fi

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY RESULTS"
echo -e "  Passed assertions: ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed assertions: ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL $PASSED_TESTS ASSERTIONS PASSED! Mini-Project 10-06 is 100% operational!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ $FAILED_TESTS ASSERTION(S) FAILED! Check output above.${CLR_RESET}\n"
    exit 1
fi
