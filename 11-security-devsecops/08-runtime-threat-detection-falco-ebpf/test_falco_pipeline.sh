#!/usr/bin/env bash
# ==============================================================================
# test_falco_pipeline.sh - Automated E2E Test Suite for Mini-Project 11-08
# ==============================================================================
# End-to-end verification of container runtime threat detection with Falco eBPF:
#   1. Validates runtime dependencies (Docker, Compose, Python 3).
#   2. Spins up Falco eBPF engine, webhook alert receiver, and target container.
#   3. Validates Falco rules syntax and engine health.
#   4. Executes 5 distinct exploit attack vectors via simulate_threats.sh.
#   5. Verifies alerts captured in JSON log and webhook receiver via alert_verifier.py.
#   6. Asserts 100% interception and generates executive Markdown audit report.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PASSED_TESTS=0
FAILED_TESTS=0
REPORTS_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORTS_DIR"

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

log_header "🧪 STARTING FALCO eBPF RUNTIME THREAT DETECTION TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/5] Validating runtime dependencies..."

if command -v docker >/dev/null 2>&1; then
    assert_test "Docker CLI is available" 0
else
    assert_test "Docker CLI is available" 1
fi

if command -v python3 >/dev/null 2>&1; then
    assert_test "Python 3 is available" 0
else
    assert_test "Python 3 is available" 1
fi

# ------------------------------------------------------------------------------
# STEP 1: Launch Sandbox Containers via Docker Compose
# ------------------------------------------------------------------------------
log_step "[Step 1/5] Launching Falco eBPF sandbox containers..."

COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

if [[ -n "$COMPOSE_CMD" ]]; then
    $COMPOSE_CMD up -d --build >/dev/null 2>&1
    sleep 4
    if docker ps --format '{{.Names}}' | grep -q "falco-ebpf-engine"; then
        assert_test "Falco eBPF engine container is active" 0
    else
        assert_test "Falco eBPF engine container is active" 1
    fi

    if docker ps --format '{{.Names}}' | grep -q "victim-payment-app"; then
        assert_test "Victim target workload container is active" 0
    else
        assert_test "Victim target workload container is active" 1
    fi

    if docker ps --format '{{.Names}}' | grep -q "falco-alert-verifier"; then
        assert_test "Webhook alert receiver daemon is active" 0
    else
        assert_test "Webhook alert receiver daemon is active" 1
    fi
fi

# ------------------------------------------------------------------------------
# STEP 2: Validate Falco Engine Health & Rules
# ------------------------------------------------------------------------------
log_step "[Step 2/5] Validating Falco rules and eBPF engine status..."

if docker exec falco-ebpf-engine falco --validate /etc/falco/falco_rules.local.yaml >/dev/null 2>&1; then
    assert_test "Falco custom security rules syntax validation passed" 0
else
    assert_test "Falco custom security rules syntax validation passed" 1
fi

# ------------------------------------------------------------------------------
# STEP 3: Execute Threat Simulation
# ------------------------------------------------------------------------------
log_step "[Step 3/5] Executing 5 simulated container exploit attacks..."

if ./simulate_threats.sh --container victim-payment-app --delay 1 >/dev/null 2>&1; then
    assert_test "simulate_threats.sh executed all 5 attack scenarios" 0
else
    assert_test "simulate_threats.sh executed all 5 attack scenarios" 1
fi

# Allow brief window for Falco to flush events to webhook receiver
sleep 3
docker cp falco-alert-verifier:/app/reports/received_alerts.json "$REPORTS_DIR/received_alerts.json" >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# STEP 4: Ingest and Audit Alert Detections via alert_verifier.py
# ------------------------------------------------------------------------------
log_step "[Step 4/5] Auditing captured security events against MITRE ATT&CK rules..."

if python3 alert_verifier.py --audit \
    --log-file "$REPORTS_DIR/received_alerts.json" \
    --output-md "$REPORTS_DIR/threat_detection_report.md"; then
    assert_test "alert_verifier.py verified 100% detection rate across all threats" 0
else
    assert_test "alert_verifier.py verified 100% detection rate across all threats" 1
fi

# ------------------------------------------------------------------------------
# STEP 5: Verify Generated Report Artifact
# ------------------------------------------------------------------------------
log_step "[Step 5/5] Verifying executive Markdown compliance report..."

if [[ -f "$SCRIPT_DIR/reports/threat_detection_report.md" ]]; then
    assert_test "Executive Threat Detection Markdown report generated" 0
else
    assert_test "Executive Threat Detection Markdown report generated" 1
fi

# ------------------------------------------------------------------------------
# Test Suite Summary
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY"
echo -e "  Tests Passed : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Tests Failed : ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
echo -e "  Total Tests  : $((PASSED_TESTS + FAILED_TESTS))"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL FALCO eBPF RUNTIME THREAT TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ THREAT DETECTION TESTS FAILED. PLEASE CHECK LOGS ABOVE.${CLR_RESET}\n"
    exit 1
fi
