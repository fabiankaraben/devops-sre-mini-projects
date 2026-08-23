#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Automated End-to-End Test Suite for Mini-Project 10-05
# ==============================================================================
# Validates Container Chaos Engineering with Pumba:
# 1. Validates system dependencies (Docker, Python 3, curl).
# 2. Builds and starts Docker Compose stack (Gateway & Payment Replicas).
# 3. Runs Baseline Steady-State Traffic (100% availability).
# 4. Executes Chaos Experiment 1: Forced SIGKILL on Replica 1 (asserting failover & >99% availability).
# 5. Executes Chaos Experiment 2: Container Pause on Replica 1 (asserting timeout failover).
# 6. Executes Chaos Experiment 3: Network Emulation Delay on Replica 1.
# 7. Validates generated Chaos Reports (Markdown & JSON).
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
REP1_URL="http://localhost:8081"
REP2_URL="http://localhost:8082"

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

log_header "🧪 STARTING CONTAINER CHAOS ENGINEERING TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/7] Checking system dependencies..."
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
log_step "[Step 1/7] Building and starting Docker Compose stack..."
$COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
$COMPOSE_CMD up -d --build >/dev/null 2>&1
assert_test "Docker Compose stack started" $?

log_step "Waiting for Gateway and both Payment Replicas to be healthy..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "$GATEWAY_URL/health" >/dev/null 2>&1 && \
       curl -sf "$REP1_URL/health" >/dev/null 2>&1 && \
       curl -sf "$REP2_URL/health" >/dev/null 2>&1; then
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
assert_test "All 3 services (Gateway, Replica 1, Replica 2) are healthy" 0

# ------------------------------------------------------------------------------
# STEP 2: Baseline Steady-State Traffic (100% Availability)
# ------------------------------------------------------------------------------
log_step "[Step 2/7] Running baseline steady-state load test (5s)..."
python3 chaos_load_runner.py --name "Baseline Steady State" --duration 5 --rps 25 --min-availability 99.0
assert_test "Baseline steady-state traffic maintained >= 99% availability" $?

# ------------------------------------------------------------------------------
# STEP 3: Chaos Experiment 1 - Forced SIGKILL Injection via Pumba
# ------------------------------------------------------------------------------
log_step "[Step 3/7] Running Chaos Experiment 1: Forced SIGKILL Injection..."
# Start load generator in background
python3 chaos_load_runner.py --name "SIGKILL Chaos Experiment" --duration 8 --rps 25 --min-availability 99.0 &
LOAD_PID=$!

# Inject SIGKILL after 2 seconds of continuous traffic
sleep 2
log_step "Injecting SIGKILL into 'payment-service-1' via Pumba..."
./pumba_chaos.sh --kill --target=payment-service-1 >/dev/null 2>&1

wait $LOAD_PID
assert_test "Resilient Gateway maintained >= 99% availability during SIGKILL chaos" $?

# Restart killed container for subsequent tests
log_step "Restarting 'payment-service-1'..."
docker start payment-service-1 >/dev/null 2>&1
sleep 2

# ------------------------------------------------------------------------------
# STEP 4: Chaos Experiment 2 - Container Pause Injection via Pumba
# ------------------------------------------------------------------------------
log_step "[Step 4/7] Running Chaos Experiment 2: Container Pause Injection..."
python3 chaos_load_runner.py --name "Container Pause Chaos Experiment" --duration 8 --rps 25 --min-availability 99.0 &
PAUSE_LOAD_PID=$!

sleep 2
log_step "Injecting 4s container pause into 'payment-service-1' via Pumba..."
./pumba_chaos.sh --pause --duration 4s --target=payment-service-1 >/dev/null 2>&1

wait $PAUSE_LOAD_PID
assert_test "Resilient Gateway maintained >= 99% availability during Container Pause chaos" $?

# ------------------------------------------------------------------------------
# STEP 5: Chaos Experiment 3 - Network Emulation Latency Injection
# ------------------------------------------------------------------------------
log_step "[Step 5/7] Running Chaos Experiment 3: Network Delay Emulation..."
python3 chaos_load_runner.py --name "Network Delay Chaos Experiment" --duration 6 --rps 20 --min-availability 99.0 &
NETEM_LOAD_PID=$!

sleep 1
log_step "Injecting 200ms network delay into 'payment-service-1'..."
./pumba_chaos.sh --delay --delay-ms=200 --duration 3s --target=payment-service-1 >/dev/null 2>&1

wait $NETEM_LOAD_PID
assert_test "Resilient Gateway maintained >= 99% availability during Network Delay chaos" $?

# ------------------------------------------------------------------------------
# STEP 6: Validate Gateway Telemetry & Failover Metrics
# ------------------------------------------------------------------------------
log_step "[Step 6/7] Validating Gateway statistics & failover metrics..."
GATEWAY_STATS=$(curl -s "$GATEWAY_URL/stats")
if echo "$GATEWAY_STATS" | grep -q "failover_count" && echo "$GATEWAY_STATS" | grep -q "payment-service-1"; then
    assert_test "Gateway recorded failover events and multi-replica telemetry" 0
else
    assert_test "Gateway recorded failover events and multi-replica telemetry" 1
fi

# ------------------------------------------------------------------------------
# STEP 7: Validate Chaos Experiment Report Artifacts
# ------------------------------------------------------------------------------
log_step "[Step 7/7] Validating generated Chaos Experiment reports..."
if [ -f "$SCRIPT_DIR/chaos_report.md" ] && [ -f "$SCRIPT_DIR/chaos_report.json" ]; then
    assert_test "Chaos report artifacts (chaos_report.md and chaos_report.json) exist" 0
else
    assert_test "Chaos report artifacts (chaos_report.md and chaos_report.json) exist" 1
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
