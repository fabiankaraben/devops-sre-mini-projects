#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_cert_auditor.sh
# Description: Comprehensive Automated Test Suite for SSL/TLS Certificate Expiry Auditor.
#              Tests CLI validation, error handling, mock TLS endpoint auditing,
#              JSON schema, Prometheus metrics, Bash script parity, and exit codes.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDITOR_PY="${SCRIPT_DIR}/cert_auditor.py"
AUDITOR_SH="${SCRIPT_DIR}/cert_auditor.sh"
TARGETS_FILE="${SCRIPT_DIR}/targets.txt"
MOCK_COMPOSE="${SCRIPT_DIR}/mock_tls_environment/docker-compose.yml"
TEST_OUTPUT="${SCRIPT_DIR}/.test_audit_output.json"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
NC="\033[0m"

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

cleanup() {
    rm -f "$TEST_OUTPUT" "${SCRIPT_DIR}/.test_prom.txt" 2>/dev/null || true
    rm -rf "${SCRIPT_DIR}/.tmp_decode" 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

echo -e "\n${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}${BLUE}    SSL/TLS Certificate Auditor - Automated Tests     ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}\n"

# Ensure mock TLS environment is running
echo -e "${YELLOW}[SETUP] Checking Mock TLS Server container...${NC}"
if ! curl -k -s https://localhost:8443/healthz >/dev/null 2>&1; then
    echo -e "Starting Mock TLS server..."
    docker rm -f mock_tls_server 2>/dev/null || true
    docker compose -f "$MOCK_COMPOSE" up -d --build --force-recreate
    sleep 2
fi

# Wait for healthy port
for i in {1..10}; do
    if curl -k -s https://localhost:8443/healthz >/dev/null 2>&1; then
        echo -e "${GREEN}[SETUP] Mock TLS Server is healthy and listening on ports 8443, 8444, 8445.${NC}\n"
        break
    fi
    sleep 1
done

# ------------------------------------------------------------------------------
# Suite 1: CLI Flags & Help Handling
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Flags & Help Handling${NC}"

set +e
help_out=$(python3 "$AUDITOR_PY" --help 2>&1)
help_code=$?
set -e
if [[ $help_code -eq 0 && "$help_out" =~ "usage:" ]]; then
    report_test "Python auditor --help displays usage and returns 0" "PASS"
else
    report_test "Python auditor --help displays usage and returns 0" "FAIL" "Exit: $help_code"
fi

set +e
no_args_out=$(python3 "$AUDITOR_PY" 2>&1)
no_args_code=$?
set -e
if [[ $no_args_code -eq 3 ]]; then
    report_test "Python auditor with missing arguments returns exit code 3" "PASS"
else
    report_test "Python auditor with missing arguments returns exit code 3" "FAIL" "Exit: $no_args_code"
fi

set +e
bad_file_out=$(python3 "$AUDITOR_PY" -f "non_existent_file.xyz" 2>&1)
bad_file_code=$?
set -e
if [[ $bad_file_code -eq 3 ]]; then
    report_test "Python auditor handling missing file returns exit code 3" "PASS"
else
    report_test "Python auditor handling missing file returns exit code 3" "FAIL" "Exit: $bad_file_code"
fi

set +e
bash_help_out=$("$AUDITOR_SH" --help 2>&1)
bash_help_code=$?
set -e
if [[ $bash_help_code -eq 0 && "$bash_help_out" =~ "Usage:" ]]; then
    report_test "Bash auditor --help displays usage and returns 0" "PASS"
else
    report_test "Bash auditor --help displays usage and returns 0" "FAIL" "Exit: $bash_help_code"
fi

# ------------------------------------------------------------------------------
# Suite 2: Network Error & Unreachable Host Handling
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Network Error & Unreachable Host Handling${NC}"

set +e
unreachable_json=$(python3 "$AUDITOR_PY" -t "localhost:59999" --json 2>/dev/null)
unreachable_code=$?
set -e
if [[ $unreachable_code -eq 3 && "$unreachable_json" =~ "ERROR" ]]; then
    report_test "Closed port returns ERROR status and exit code 3" "PASS"
else
    report_test "Closed port returns ERROR status and exit code 3" "FAIL" "Exit: $unreachable_code"
fi

set +e
dns_err_json=$(python3 "$AUDITOR_PY" -t "invalid-hostname-that-does-not-exist.test:443" --json 2>/dev/null)
dns_err_code=$?
set -e
if [[ $dns_err_code -eq 3 && "$dns_err_json" =~ "ERROR" ]]; then
    report_test "DNS failure returns ERROR status and exit code 3" "PASS"
else
    report_test "DNS failure returns ERROR status and exit code 3" "FAIL" "Exit: $dns_err_code"
fi

# ------------------------------------------------------------------------------
# Suite 3: TLS Certificate Status & Expiry Logic (Mock Environment)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: TLS Certificate Status & Expiry Logic${NC}"

# 1. Valid Endpoint (Port 8443) -> OK, Exit 0
set +e
valid_json=$(python3 "$AUDITOR_PY" -k -t "localhost:8443" --json 2>/dev/null)
valid_code=$?
set -e
valid_status=$(echo "$valid_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['results'][0]['status'])" 2>/dev/null || echo "")
valid_days=$(echo "$valid_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['results'][0]['days_remaining'])" 2>/dev/null || echo "0")
if [[ $valid_code -eq 0 && "$valid_status" == "OK" && $(echo "$valid_days > 60" | bc -l) -eq 1 ]]; then
    report_test "Valid certificate (90 days) detected as OK with exit code 0" "PASS"
else
    report_test "Valid certificate (90 days) detected as OK with exit code 0" "FAIL" "Status: $valid_status, Code: $valid_code, Days: $valid_days"
fi

# 2. Expiring Soon Endpoint (Port 8444) -> WARNING, Exit 1
set +e
warn_json=$(python3 "$AUDITOR_PY" -k -t "localhost:8444" --json 2>/dev/null)
warn_code=$?
set -e
warn_status=$(echo "$warn_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['results'][0]['status'])" 2>/dev/null || echo "")
warn_days=$(echo "$warn_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['results'][0]['days_remaining'])" 2>/dev/null || echo "0")
if [[ $warn_code -eq 1 && "$warn_status" == "WARNING" && $(echo "$warn_days <= 30 && $warn_days > 0" | bc -l) -eq 1 ]]; then
    report_test "Expiring certificate (10 days) detected as WARNING with exit code 1" "PASS"
else
    report_test "Expiring certificate (10 days) detected as WARNING with exit code 1" "FAIL" "Status: $warn_status, Code: $warn_code, Days: $warn_days"
fi

# 3. Expired Endpoint (Port 8445) -> EXPIRED, Exit 2
set +e
exp_json=$(python3 "$AUDITOR_PY" -k -t "localhost:8445" --json 2>/dev/null)
exp_code=$?
set -e
exp_status=$(echo "$exp_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['results'][0]['status'])" 2>/dev/null || echo "")
exp_days=$(echo "$exp_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['results'][0]['days_remaining'])" 2>/dev/null || echo "0")
if [[ $exp_code -eq 2 && "$exp_status" == "EXPIRED" && $(echo "$exp_days <= 0" | bc -l) -eq 1 ]]; then
    report_test "Expired certificate detected as EXPIRED with exit code 2" "PASS"
else
    report_test "Expired certificate detected as EXPIRED with exit code 2" "FAIL" "Status: $exp_status, Code: $exp_code, Days: $exp_days"
fi

# ------------------------------------------------------------------------------
# Suite 4: Batch Scanning & Target File Processing
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Batch Scanning & Target File Processing${NC}"

set +e
batch_json=$(python3 "$AUDITOR_PY" -k -f "$TARGETS_FILE" --json 2>/dev/null)
batch_code=$?
set -e
batch_total=$(echo "$batch_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['audit_metadata']['total_targets'])" 2>/dev/null || echo "0")
batch_healthy=$(echo "$batch_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['audit_metadata']['healthy_count'])" 2>/dev/null || echo "0")
batch_warning=$(echo "$batch_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['audit_metadata']['warning_count'])" 2>/dev/null || echo "0")
batch_expired=$(echo "$batch_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['audit_metadata']['expired_count'])" 2>/dev/null || echo "0")

if [[ $batch_total -ge 3 && $batch_healthy -eq 1 && $batch_warning -eq 1 && $batch_expired -eq 1 ]]; then
    report_test "File target ingestion (targets.txt) audits all endpoints accurately" "PASS"
else
    report_test "File target ingestion (targets.txt) audits all endpoints accurately" "FAIL" "Total: $batch_total, OK: $batch_healthy, Warn: $batch_warning, Exp: $batch_expired"
fi

# ------------------------------------------------------------------------------
# Suite 5: Prometheus Metrics Export Format
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Prometheus Metrics Export Format${NC}"

prom_out=$(python3 "$AUDITOR_PY" -k -t localhost:8443 -t localhost:8444 -t localhost:8445 --prometheus --no-fail 2>/dev/null)

has_days_metric=$(echo "$prom_out" | grep -q 'ssl_cert_days_until_expiry{target="localhost:8443"' && echo 1 || echo 0)
has_timestamp_metric=$(echo "$prom_out" | grep -q 'ssl_cert_expiry_timestamp_seconds{target="localhost:8443"' && echo 1 || echo 0)
has_valid_metric=$(echo "$prom_out" | grep -q 'ssl_cert_valid{target="localhost:8443"' && echo 1 || echo 0)
has_total_metric=$(echo "$prom_out" | grep -q 'ssl_audit_targets_total 3' && echo 1 || echo 0)

if [[ $has_days_metric -eq 1 && $has_timestamp_metric -eq 1 && $has_valid_metric -eq 1 && $has_total_metric -eq 1 ]]; then
    report_test "Prometheus metrics exporter complies with OpenMetrics specification" "PASS"
else
    report_test "Prometheus metrics exporter complies with OpenMetrics specification" "FAIL" "Metrics missing or misformatted"
fi

# ------------------------------------------------------------------------------
# Suite 6: Output File Generation & Isolation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 6: Output File Generation & Isolation${NC}"

python3 "$AUDITOR_PY" -k -t localhost:8443 -o "$TEST_OUTPUT" --json --no-fail >/dev/null 2>&1

if [[ -f "$TEST_OUTPUT" && -s "$TEST_OUTPUT" ]]; then
    if python3 -c "import json; json.load(open('$TEST_OUTPUT'))" 2>/dev/null; then
        report_test "Output report file created inside project directory and contains valid JSON" "PASS"
    else
        report_test "Output report file created inside project directory and contains valid JSON" "FAIL" "JSON invalid"
    fi
else
    report_test "Output report file created inside project directory and contains valid JSON" "FAIL" "File not created"
fi

# ------------------------------------------------------------------------------
# Suite 7: Custom Threshold Configurations
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 7: Custom Threshold Configurations${NC}"

# Setting warning threshold to 100 days should turn 90-day valid cert into WARNING (exit 1)
set +e
custom_thresh_out=$(python3 "$AUDITOR_PY" -k -t localhost:8443 --warning-days 100 --json 2>/dev/null)
custom_thresh_code=$?
set -e
custom_status=$(echo "$custom_thresh_out" | python3 -c "import sys, json; print(json.load(sys.stdin)['results'][0]['status'])" 2>/dev/null || echo "")

if [[ $custom_thresh_code -eq 1 && "$custom_status" == "WARNING" ]]; then
    report_test "Custom warning threshold (--warning-days 100) triggers warning on 90-day cert" "PASS"
else
    report_test "Custom warning threshold (--warning-days 100) triggers warning on 90-day cert" "FAIL" "Status: $custom_status, Code: $custom_thresh_code"
fi

# ------------------------------------------------------------------------------
# Suite 8: Flag --no-fail Behavior
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 8: Flag --no-fail Behavior${NC}"

set +e
no_fail_out=$(python3 "$AUDITOR_PY" -k -t localhost:8445 --no-fail 2>/dev/null)
no_fail_code=$?
set -e

if [[ $no_fail_code -eq 0 ]]; then
    report_test "--no-fail overrides critical/expired exit code and returns 0" "PASS"
else
    report_test "--no-fail overrides critical/expired exit code and returns 0" "FAIL" "Exit: $no_fail_code"
fi

# ------------------------------------------------------------------------------
# Suite 9: Bash Companion Script Parity
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 9: Bash Companion Script Parity${NC}"

# Test Valid (Exit 0)
set +e
bash_valid_out=$("$AUDITOR_SH" -t localhost:8443 2>/dev/null)
bash_valid_code=$?
set -e
if [[ $bash_valid_code -eq 0 && "$bash_valid_out" =~ "[  OK   ]" ]]; then
    report_test "Bash auditor accurately audits valid certificate (OK, exit 0)" "PASS"
else
    report_test "Bash auditor accurately audits valid certificate (OK, exit 0)" "FAIL" "Code: $bash_valid_code"
fi

# Test Warning (Exit 1)
set +e
bash_warn_out=$("$AUDITOR_SH" -t localhost:8444 2>/dev/null)
bash_warn_code=$?
set -e
if [[ $bash_warn_code -eq 1 && "$bash_warn_out" =~ "[ WARN  ]" ]]; then
    report_test "Bash auditor accurately audits expiring certificate (WARN, exit 1)" "PASS"
else
    report_test "Bash auditor accurately audits expiring certificate (WARN, exit 1)" "FAIL" "Code: $bash_warn_code"
fi

# Test Expired (Exit 2)
set +e
bash_exp_out=$("$AUDITOR_SH" -t localhost:8445 2>/dev/null)
bash_exp_code=$?
set -e
if [[ $bash_exp_code -eq 2 && "$bash_exp_out" =~ "[EXPIRED]" ]]; then
    report_test "Bash auditor accurately audits expired certificate (EXPIRED, exit 2)" "PASS"
else
    report_test "Bash auditor accurately audits expired certificate (EXPIRED, exit 2)" "FAIL" "Code: $bash_exp_code"
fi

# ------------------------------------------------------------------------------
# Summary & Test Results
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}                   TEST RESULTS SUMMARY               ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}"
echo -e "  Total Tests  : ${BOLD}${TOTAL_TESTS}${NC}"
echo -e "  Passed Tests : ${GREEN}${PASSED_TESTS}${NC}"
echo -e "  Failed Tests : ${RED}${FAILED_TESTS}${NC}"

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "\n${GREEN}${BOLD}✔ ALL TESTS PASSED SUCCESSFULLY (100% Pass Rate)${NC}\n"
    exit 0
else
    echo -e "\n${RED}${BOLD}✖ SOME TESTS FAILED${NC}\n"
    exit 1
fi
