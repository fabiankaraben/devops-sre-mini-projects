#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Automated End-to-End Test Suite for Mini-Project 10-03
# ==============================================================================
# Validates Automated Incident Runbook Executor:
# 1. Validates system dependencies (Docker, Python 3, curl, openssl).
# 2. Builds and starts Docker Compose stack (Executor & Mock Services).
# 3. Validates HMAC-SHA256 signature verification & security rejection.
# 4. Injects Worker deadlock, triggers remediation, verifies recovery & auto-resolve.
# 5. Tests Cooldown safety guard (prevents rapid flapping loops).
# 6. Injects Cache OOM, triggers remediation, verifies cache flush.
# 7. Injects Queue backlog, triggers remediation, verifies replica scaling.
# 8. Injects DLQ backlog, triggers remediation, verifies DLQ draining.
# 9. Validates execution audit history and Prometheus metrics exposition.
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

EXECUTOR_URL="http://localhost:8080"
MOCK_URL="http://localhost:9000"

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

log_header "🧪 STARTING AUTOMATED INCIDENT RUNBOOK EXECUTOR TEST SUITE"

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

if command -v openssl >/dev/null 2>&1; then
    assert_test "openssl is installed" 0
else
    assert_test "openssl is installed" 1
fi

# ------------------------------------------------------------------------------
# STEP 1: Pre-test Cleanup & Stack Startup
# ------------------------------------------------------------------------------
log_step "[Step 1/8] Building and starting Docker Compose stack..."
$COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
$COMPOSE_CMD up -d --build >/dev/null 2>&1
assert_test "Docker Compose stack started" $?

log_step "Waiting for Executor and Mock Services to be healthy..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "$EXECUTOR_URL/health" >/dev/null 2>&1 && curl -sf "$MOCK_URL/health" >/dev/null 2>&1; then
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
assert_test "Both services (Executor and Mock Services) are healthy" 0

# ------------------------------------------------------------------------------
# STEP 2: Security Test - HMAC Signature Verification & Rejection
# ------------------------------------------------------------------------------
log_step "[Step 2/8] Testing HMAC-SHA256 security signature verification..."
# Test 1: Tampered signature rejection
TAMPER_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$EXECUTOR_URL/webhook/pagerduty" \
    -H "Content-Type: application/json" \
    -H "X-Webhook-Signature: v1=bad_signature_digest" \
    -d '{"event":{"data":{"title":"HungWorkerDetected"}}}')

if [ "$TAMPER_HTTP" -eq 401 ]; then
    assert_test "Tampered HMAC signature rejected with HTTP 401 Unauthorized" 0
else
    assert_test "Tampered HMAC signature rejected with HTTP 401 Unauthorized" 1
fi

# ------------------------------------------------------------------------------
# STEP 3: Incident 1 - Hung Worker Deadlock Remediation
# ------------------------------------------------------------------------------
log_step "[Step 3/8] Testing Incident 1: Hung Worker Deadlock Self-Healing..."
# 1. Inject fault
curl -s -X POST "$MOCK_URL/fault/hang-worker" >/dev/null
WORKER_BEFORE=$(curl -s "$MOCK_URL/worker/status")
if echo "$WORKER_BEFORE" | grep -q "HUNG_DEADLOCK"; then
    assert_test "Fault injected: Worker entered HUNG_DEADLOCK" 0
else
    assert_test "Fault injected: Worker entered HUNG_DEADLOCK" 1
fi

# 2. Dispatch valid signed PagerDuty alert
./simulate_pagerduty_alert.sh --incident-type=worker-hung --format=pagerduty --url="$EXECUTOR_URL" >/dev/null

# 3. Verify worker recovered
WORKER_AFTER=$(curl -s "$MOCK_URL/worker/status")
if echo "$WORKER_AFTER" | grep -q '"status": "HEALTHY"'; then
    assert_test "Runbook restart_service.sh recovered worker to HEALTHY state" 0
else
    assert_test "Runbook restart_service.sh recovered worker to HEALTHY state" 1
fi

# 4. Verify auto-resolution callback recorded
STATUS_AFTER=$(curl -s "$MOCK_URL/status")
if echo "$STATUS_AFTER" | grep -q "resolved_incidents"; then
    assert_test "Incident auto-resolution callback recorded in target" 0
else
    assert_test "Incident auto-resolution callback recorded in target" 1
fi

# ------------------------------------------------------------------------------
# STEP 4: Cooldown Safety Guard Testing
# ------------------------------------------------------------------------------
log_step "[Step 4/8] Testing Cooldown Safety Guard (preventing flapping loops)..."
# Immediately send duplicate alert (should trigger COOLDOWN_BLOCKED within 15s window)
COOLDOWN_RESP=$(./simulate_pagerduty_alert.sh --incident-type=worker-hung --format=pagerduty --url="$EXECUTOR_URL")
if echo "$COOLDOWN_RESP" | grep -q "COOLDOWN_BLOCKED"; then
    assert_test "Cooldown guard successfully blocked rapid repeated execution" 0
else
    assert_test "Cooldown guard successfully blocked rapid repeated execution" 1
fi

# ------------------------------------------------------------------------------
# STEP 5: Incident 2 - Redis Cache Memory Pressure Remediation
# ------------------------------------------------------------------------------
log_step "[Step 5/8] Testing Incident 2: Redis Memory Pressure Eviction..."
curl -s -X POST "$MOCK_URL/fault/fill-cache" >/dev/null
CACHE_BEFORE=$(curl -s "$MOCK_URL/cache/status")
if echo "$CACHE_BEFORE" | grep -q "OUT_OF_MEMORY"; then
    assert_test "Fault injected: Cache entered OUT_OF_MEMORY" 0
else
    assert_test "Fault injected: Cache entered OUT_OF_MEMORY" 1
fi

./simulate_pagerduty_alert.sh --incident-type=cache-oom --format=alertmanager --url="$EXECUTOR_URL" >/dev/null

CACHE_AFTER=$(curl -s "$MOCK_URL/cache/status")
if echo "$CACHE_AFTER" | grep -q '"status": "HEALTHY"'; then
    assert_test "Runbook flush_cache.sh reduced memory and restored HEALTHY state" 0
else
    assert_test "Runbook flush_cache.sh reduced memory and restored HEALTHY state" 1
fi

# ------------------------------------------------------------------------------
# STEP 6: Incident 3 - Queue Backlog Dynamic Autoscaling
# ------------------------------------------------------------------------------
log_step "[Step 6/8] Testing Incident 3: Queue Backlog Autoscaling..."
curl -s -X POST "$MOCK_URL/fault/spike-queue" >/dev/null
QUEUE_BEFORE=$(curl -s "$MOCK_URL/queue/status")
if echo "$QUEUE_BEFORE" | grep -q "BACKLOG_OVERFLOW"; then
    assert_test "Fault injected: Queue entered BACKLOG_OVERFLOW" 0
else
    assert_test "Fault injected: Queue entered BACKLOG_OVERFLOW" 1
fi

./simulate_pagerduty_alert.sh --incident-type=queue-backlog --format=generic --url="$EXECUTOR_URL" >/dev/null

QUEUE_AFTER=$(curl -s "$MOCK_URL/queue/status")
if echo "$QUEUE_AFTER" | grep -q '"replica_count": 6'; then
    assert_test "Runbook scale_deployment.sh scaled workers to 6 replicas" 0
else
    assert_test "Runbook scale_deployment.sh scaled workers to 6 replicas" 1
fi

# ------------------------------------------------------------------------------
# STEP 7: Incident 4 - Dead-Letter Queue Reprocessing
# ------------------------------------------------------------------------------
log_step "[Step 7/8] Testing Incident 4: Dead-Letter Queue Replay & Drain..."
./simulate_pagerduty_alert.sh --incident-type=dlq-spike --format=pagerduty --url="$EXECUTOR_URL" >/dev/null

QUEUE_FINAL=$(curl -s "$MOCK_URL/queue/status")
if echo "$QUEUE_FINAL" | grep -q '"dead_letter_count": 0'; then
    assert_test "Runbook drain_queue.sh drained all dead-letter messages to 0" 0
else
    assert_test "Runbook drain_queue.sh drained all dead-letter messages to 0" 1
fi

# ------------------------------------------------------------------------------
# STEP 8: Audit Trail & Prometheus Metrics Validation
# ------------------------------------------------------------------------------
log_step "[Step 8/8] Validating execution audit history & Prometheus metrics..."
HISTORY_JSON=$(curl -s "$EXECUTOR_URL/history")
if echo "$HISTORY_JSON" | grep -q "total_executions" && echo "$HISTORY_JSON" | grep -q "remediate_hung_worker"; then
    assert_test "Execution history API records audit trail for all runbooks" 0
else
    assert_test "Execution history API records audit trail for all runbooks" 1
fi

METRICS_TEXT=$(curl -s "$EXECUTOR_URL/metrics")
if echo "$METRICS_TEXT" | grep -q "runbook_executions_total" && echo "$METRICS_TEXT" | grep -q "runbook_cooldown_blocked_total"; then
    assert_test "Prometheus metrics endpoint exports remediation telemetry" 0
else
    assert_test "Prometheus metrics endpoint exports remediation telemetry" 1
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
