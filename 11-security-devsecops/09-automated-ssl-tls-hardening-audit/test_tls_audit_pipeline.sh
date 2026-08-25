#!/usr/bin/env bash
# ==============================================================================
# test_tls_audit_pipeline.sh - Automated SSL/TLS Cipher Hardening Test Suite
# ==============================================================================
# Validates the full TLS audit pipeline:
#   1. Environment & tool dependencies (Docker, OpenSSL, Python 3)
#   2. PKI and Certificate Generation
#   3. Mock weak & hardened Nginx container deployments
#   4. TLS scanning and security score grading
#   5. Multi-format reporting (JSON, Markdown, HTML)
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    local name="$1"
    local status="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$status" -eq 0 ]; then
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] $name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] $name"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 STARTING AUTOMATED SSL/TLS CIPHER HARDENING TEST SUITE"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Validate Dependencies
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [Step 1/5] Validating runtime tools & dependencies...${CLR_RESET}"

command -v docker >/dev/null 2>&1
record_result "Docker CLI is installed and accessible" $?

command -v openssl >/dev/null 2>&1
record_result "OpenSSL CLI is installed and accessible" $?

command -v python3 >/dev/null 2>&1
record_result "Python 3 runtime is installed and accessible" $?

# ------------------------------------------------------------------------------
# 2. PKI & Certificate Generation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 2/5] Generating local PKI and TLS Server Certificates...${CLR_RESET}"
./generate_certificates.sh >/dev/null 2>&1

test -f "$SCRIPT_DIR/certs/ca.crt" && test -f "$SCRIPT_DIR/certs/server.crt" && test -f "$SCRIPT_DIR/certs/server.key"
record_result "Root CA and Server Certificates generated successfully" $?

# ------------------------------------------------------------------------------
# 3. Deploy Mock Nginx Endpoints
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 3/5] Deploying mock weak & hardened Nginx endpoints...${CLR_RESET}"

docker compose up -d --build >/dev/null 2>&1

# Wait for containers to be ready
ATTEMPTS=0
MAX_ATTEMPTS=15
READY=false
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if curl -k -s https://localhost:8443/ >/dev/null 2>&1 && curl -k -s https://localhost:9443/ >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
    ATTEMPTS=$((ATTEMPTS + 1))
done

if [ "$READY" = true ]; then
    record_result "Both mock HTTPS endpoints (weak on :8443, hardened on :9443) are healthy" 0
else
    record_result "Both mock HTTPS endpoints (weak on :8443, hardened on :9443) are healthy" 1
fi

# ------------------------------------------------------------------------------
# 4. Execute TLS Hardening Scanner
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 4/5] Executing automated TLS scanner and grading engine...${CLR_RESET}"

./tls_audit.sh >/dev/null 2>&1
record_result "tls_audit.sh completed audit scan across endpoints" $?

# Verify JSON findings
JSON_REPORT="$SCRIPT_DIR/reports/tls_audit_report.json"
test -f "$JSON_REPORT"
record_result "JSON report artifact generated at reports/tls_audit_report.json" $?

# Check Weak Endpoint Results
WEAK_GRADE=$(python3 -c "
import json
with open('$JSON_REPORT') as f:
    d = json.load(f)
for ep in d['endpoints']:
    if '8443' in ep['target']:
        print(ep['grade'])
        break
")

WEAK_STATUS=$(python3 -c "
import json
with open('$JSON_REPORT') as f:
    d = json.load(f)
for ep in d['endpoints']:
    if '8443' in ep['target']:
        print(ep['status'])
        break
")

if [ "$WEAK_STATUS" = "FAIL" ] && [[ "$WEAK_GRADE" =~ ^(F|D|C)$ ]]; then
    record_result "Weak endpoint (:8443) correctly flagged as FAIL with Grade $WEAK_GRADE" 0
else
    record_result "Weak endpoint (:8443) correctly flagged as FAIL with Grade $WEAK_GRADE" 1
fi

# Check Hardened Endpoint Results
HARDENED_GRADE=$(python3 -c "
import json
with open('$JSON_REPORT') as f:
    d = json.load(f)
for ep in d['endpoints']:
    if '9443' in ep['target']:
        print(ep['grade'])
        break
")

HARDENED_STATUS=$(python3 -c "
import json
with open('$JSON_REPORT') as f:
    d = json.load(f)
for ep in d['endpoints']:
    if '9443' in ep['target']:
        print(ep['status'])
        break
")

if [ "$HARDENED_STATUS" = "PASS" ] && [ "$HARDENED_GRADE" = "A+" ]; then
    record_result "Hardened endpoint (:9443) verified as PASS with Grade A+" 0
else
    record_result "Hardened endpoint (:9443) verified as PASS with Grade A+" 1
fi

# ------------------------------------------------------------------------------
# 5. Verify Multi-Format Reports
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 5/5] Verifying Markdown and HTML report generation...${CLR_RESET}"

test -s "$SCRIPT_DIR/reports/tls_audit_report.md"
record_result "Markdown executive report (reports/tls_audit_report.md) is valid" $?

test -s "$SCRIPT_DIR/reports/tls_audit_report.html"
record_result "HTML dashboard report (reports/tls_audit_report.html) is valid" $?

# ------------------------------------------------------------------------------
# Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  📊 TEST SUITE SUMMARY"
echo "======================================================================${CLR_RESET}"
echo "  Tests Passed : $PASSED_TESTS"
echo "  Tests Failed : $FAILED_TESTS"
echo "  Total Tests  : $TOTAL_TESTS"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL SSL/TLS HARDENING AUDIT TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. Please review the output above.${CLR_RESET}\n"
    exit 1
fi
