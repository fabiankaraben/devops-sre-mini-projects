#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_health_check.sh
# Description: Automated Test Suite for System Resource Health Checker.
#              Tests CLI flag parsing, threshold enforcement, exit codes,
#              JSON schema validity, and stress simulation integration.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK="${SCRIPT_DIR}/health_check.sh"
STRESS_SIM="${SCRIPT_DIR}/stress_simulator.sh"

# Color helpers for test reporting
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

report_test() {
    local name="$1"
    local result="$2"
    local details="${3:-}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$result" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${GREEN}PASS${NC}] ${name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${RED}FAIL${NC}] ${name}"
        if [[ -n "$details" ]]; then
            echo -e "         ${YELLOW}Details: ${details}${NC}"
        fi
    fi
}

validate_json() {
    local json_str="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$json_str" | jq . >/dev/null 2>&1
        return $?
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys, json; json.loads(sys.stdin.read())" <<< "$json_str" >/dev/null 2>&1
        return $?
    else
        return 0
    fi
}

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}  System Resource Health Checker - Automated Tests  ${NC}"
echo -e "${BLUE}======================================================${NC}\n"

# ------------------------------------------------------------------------------
# Test 1: CLI Flags --help and --version
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Arguments & Help Handling${NC}"

set +e
output=$("$HEALTH_CHECK" --help 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 0 && "$output" =~ "Usage:" ]]; then
    report_test "--help displays usage and exits 0" "PASS"
else
    report_test "--help displays usage and exits 0" "FAIL" "Exit code: ${exit_code}"
fi

set +e
output=$("$HEALTH_CHECK" --version 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 0 && "$output" =~ "version" ]]; then
    report_test "--version displays version string and exits 0" "PASS"
else
    report_test "--version displays version string and exits 0" "FAIL" "Exit code: ${exit_code}"
fi

# ------------------------------------------------------------------------------
# Test 2: Invalid CLI Arguments & Validation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Error Handling & Invalid Inputs${NC}"

set +e
output=$("$HEALTH_CHECK" --invalid-flag 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 3 ]]; then
    report_test "Unknown flag triggers exit code 3 (UNKNOWN)" "PASS"
else
    report_test "Unknown flag triggers exit code 3 (UNKNOWN)" "FAIL" "Expected 3, got: ${exit_code}"
fi

set +e
output=$("$HEALTH_CHECK" --cpu-max 150 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 3 ]]; then
    report_test "Out-of-range percentage triggers exit code 3" "PASS"
else
    report_test "Out-of-range percentage triggers exit code 3" "FAIL" "Expected 3, got: ${exit_code}"
fi

set +e
output=$("$HEALTH_CHECK" --disk-path "/non_existent_path_test_123" 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 3 ]]; then
    report_test "Non-existent disk path triggers exit code 3" "PASS"
else
    report_test "Non-existent disk path triggers exit code 3" "FAIL" "Expected 3, got: ${exit_code}"
fi

# ------------------------------------------------------------------------------
# Test 3: Normal / Healthy Baseline Run
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Baseline Normal Execution${NC}"

set +e
# Set high thresholds so normal operation will be OK
output=$("$HEALTH_CHECK" --cpu-max 100 --mem-max 100 --disk-max 100 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 0 ]]; then
    report_test "Baseline health check returns exit code 0 (OK)" "PASS"
else
    report_test "Baseline health check returns exit code 0 (OK)" "FAIL" "Got exit code: ${exit_code}"
fi

if validate_json "$output"; then
    report_test "Baseline output produces valid JSON" "PASS"
else
    report_test "Baseline output produces valid JSON" "FAIL" "Invalid JSON structure"
fi

if [[ "$output" =~ "\"status\": \"OK\"" && "$output" =~ "\"exit_code\": 0" ]]; then
    report_test "JSON payload contains status OK and exit_code 0" "PASS"
else
    report_test "JSON payload contains status OK and exit_code 0" "FAIL" "Missing expected status fields"
fi

# ------------------------------------------------------------------------------
# Test 4: Warning Threshold Violation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Warning Threshold Triggers${NC}"

set +e
# Set low disk warning threshold (e.g. 1%) which is guaranteed to be exceeded by any active disk
output=$("$HEALTH_CHECK" --disk-max 1 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 1 ]]; then
    report_test "Exceeded disk threshold triggers exit code 1 (WARNING)" "PASS"
else
    report_test "Exceeded disk threshold triggers exit code 1 (WARNING)" "FAIL" "Expected exit code 1, got: ${exit_code}"
fi

if [[ "$output" =~ "\"status\": \"WARNING\"" && "$output" =~ "exceeds warning threshold" ]]; then
    report_test "JSON payload contains status WARNING and alerts entry" "PASS"
else
    report_test "JSON payload contains status WARNING and alerts entry" "FAIL" "Expected warning alert in JSON"
fi

# ------------------------------------------------------------------------------
# Test 5: Critical Threshold Violation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Critical Threshold Triggers${NC}"

set +e
# Set critical threshold to 1% to force critical breach
output=$("$HEALTH_CHECK" --disk-max 1 --disk-crit 2 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 2 ]]; then
    report_test "Exceeded critical threshold triggers exit code 2 (CRITICAL)" "PASS"
else
    report_test "Exceeded critical threshold triggers exit code 2 (CRITICAL)" "FAIL" "Expected exit code 2, got: ${exit_code}"
fi

if [[ "$output" =~ "\"status\": \"CRITICAL\"" && "$output" =~ "exceeds critical threshold" ]]; then
    report_test "JSON payload contains status CRITICAL and critical alert" "PASS"
else
    report_test "JSON payload contains status CRITICAL and critical alert" "FAIL" "Missing critical alert in JSON"
fi

# ------------------------------------------------------------------------------
# Test 6: Stress Simulator Companion Integration
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 6: Stress Simulator Companion Integration${NC}"

# Start CPU stress in background for 6 seconds
"$STRESS_SIM" --cpu 4 --duration 6 >/dev/null 2>&1 &
STRESS_PID=$!

# Give stress workers half a second to ramp up CPU
sleep 0.5

set +e
# Check health with a strict CPU warning threshold of 20%
stress_check_output=$("$HEALTH_CHECK" --cpu-max 20 --sample-interval 1 2>&1)
stress_exit_code=$?
set -e

# Wait for stress process to finish
wait "$STRESS_PID" 2>/dev/null || true

if [[ $stress_exit_code -eq 1 || $stress_exit_code -eq 2 ]]; then
    report_test "Synthetic CPU stress triggers WARNING/CRITICAL exit code ($stress_exit_code)" "PASS"
else
    report_test "Synthetic CPU stress triggers WARNING/CRITICAL exit code ($stress_exit_code)" "FAIL" "Expected exit code 1 or 2, got: ${stress_exit_code}"
fi

if validate_json "$stress_check_output"; then
    report_test "Stress test output conforms to valid JSON schema" "PASS"
else
    report_test "Stress test output conforms to valid JSON schema" "FAIL" "Invalid JSON produced under stress"
fi

# ------------------------------------------------------------------------------
# Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}======================================================${NC}"
echo -e "  Test Results: ${PASSED_TESTS}/${TOTAL_TESTS} Passed"
if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "  Status: ${GREEN}ALL TESTS PASSED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 0
else
    echo -e "  Status: ${RED}${FAILED_TESTS} TESTS FAILED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 1
fi
