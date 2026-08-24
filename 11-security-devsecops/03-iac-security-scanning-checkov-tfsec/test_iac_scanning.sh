#!/usr/bin/env bash
# ==============================================================================
# test_iac_scanning.sh - Automated Verification Suite for IaC Security Scanning
# ==============================================================================
# Executes end-to-end validation of Checkov policy scanning, SARIF generation,
# CI/CD gate blocking on vulnerable manifests, approval on remediated manifests,
# framework-specific scans, and compliance scorecard generation.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    local test_name="$1"
    local status="$2"
    local details="${3:-}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$status" -eq 0 ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${test_name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${test_name} (Exit Code: ${status}) ${details}"
    fi
}

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🧪 STARTING IaC SECURITY SCANNING VERIFICATION TEST SUITE"
echo "======================================================================${CLR_RESET}"

# ------------------------------------------------------------------------------
# Step 0: Validate Prerequisites
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 0/6] Validating environment dependencies...${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    record_result "Docker CLI is available" 0
else
    record_result "Docker CLI is available" 1 "Docker is required"
fi

if command -v python3 >/dev/null 2>&1; then
    record_result "Python 3 is available for scorecard analysis" 0
else
    record_result "Python 3 is available for scorecard analysis" 1
fi

# ------------------------------------------------------------------------------
# Step 1: Verify Manifest Fixtures Existence
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 1/6] Verifying IaC manifest test fixtures...${CLR_RESET}"

if [ -f "iac_fixtures/vulnerable_infrastructure/terraform/main.tf" ] && \
   [ -f "iac_fixtures/vulnerable_infrastructure/kubernetes/deployment.yaml" ] && \
   [ -f "iac_fixtures/vulnerable_infrastructure/docker/Dockerfile.insecure" ]; then
    record_result "Vulnerable IaC fixtures are present (Terraform, K8s, Dockerfile)" 0
else
    record_result "Vulnerable IaC fixtures are present (Terraform, K8s, Dockerfile)" 1
fi

if [ -f "iac_fixtures/remediated_infrastructure/terraform/main.tf" ] && \
   [ -f "iac_fixtures/remediated_infrastructure/kubernetes/deployment.yaml" ] && \
   [ -f "iac_fixtures/remediated_infrastructure/docker/Dockerfile.hardened" ]; then
    record_result "Remediated IaC fixtures are present (Terraform, K8s, Dockerfile)" 0
else
    record_result "Remediated IaC fixtures are present (Terraform, K8s, Dockerfile)" 1
fi

# ------------------------------------------------------------------------------
# Step 2: Audit Vulnerable Infrastructure (Expecting CI Gate Failure)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 2/6] Auditing vulnerable infrastructure (Expecting Gate FAILURE)...${CLR_RESET}"

set +e
./iac_security_audit.sh --target vulnerable --strict >/dev/null 2>&1
VULN_STATUS=$?
set -e

if [ "$VULN_STATUS" -ne 0 ]; then
    record_result "Checkov CI gate BLOCKS vulnerable infrastructure (non-zero exit code)" 0
else
    record_result "Checkov CI gate BLOCKS vulnerable infrastructure" 1 "Expected failure but got exit code 0"
fi

if [ -f "reports/vulnerable_checkov_report.json" ] && [ -s "reports/vulnerable_checkov_report.json" ]; then
    record_result "Vulnerable infrastructure JSON audit report generated" 0
else
    record_result "Vulnerable infrastructure JSON audit report generated" 1
fi

if [ -f "reports/vulnerable_checkov_report.sarif" ] && [ -s "reports/vulnerable_checkov_report.sarif" ]; then
    record_result "Vulnerable infrastructure SARIF v2.1.0 report generated" 0
else
    record_result "Vulnerable infrastructure SARIF v2.1.0 report generated" 1
fi

# ------------------------------------------------------------------------------
# Step 3: Audit Remediated Infrastructure (Expecting CI Gate Success)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 3/6] Auditing remediated infrastructure (Expecting Gate SUCCESS)...${CLR_RESET}"

set +e
./iac_security_audit.sh --target remediated --strict >/dev/null 2>&1
REMED_STATUS=$?
set -e

if [ "$REMED_STATUS" -eq 0 ]; then
    record_result "Checkov CI gate PASSES remediated infrastructure (exit code 0)" 0
else
    record_result "Checkov CI gate PASSES remediated infrastructure" 1 "Expected success but got non-zero code"
fi

if [ -f "reports/remediated_checkov_report.json" ] && [ -s "reports/remediated_checkov_report.json" ]; then
    record_result "Remediated infrastructure JSON audit report generated" 0
else
    record_result "Remediated infrastructure JSON audit report generated" 1
fi

if [ -f "reports/remediated_checkov_report.sarif" ] && [ -s "reports/remediated_checkov_report.sarif" ]; then
    record_result "Remediated infrastructure SARIF v2.1.0 report generated" 0
else
    record_result "Remediated infrastructure SARIF v2.1.0 report generated" 1
fi

# ------------------------------------------------------------------------------
# Step 4: Framework-Specific Audits
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 4/6] Validating framework-specific scanning...${CLR_RESET}"

set +e
./iac_security_audit.sh --target remediated --framework terraform >/dev/null 2>&1
TF_STATUS=$?
./iac_security_audit.sh --target remediated --framework kubernetes >/dev/null 2>&1
K8S_STATUS=$?
./iac_security_audit.sh --target remediated --framework dockerfile >/dev/null 2>&1
DOCKER_STATUS=$?
set -e

if [ "$TF_STATUS" -eq 0 ]; then
    record_result "Framework filter: Terraform scan executed successfully" 0
else
    record_result "Framework filter: Terraform scan executed successfully" 1
fi

if [ "$K8S_STATUS" -eq 0 ]; then
    record_result "Framework filter: Kubernetes scan executed successfully" 0
else
    record_result "Framework filter: Kubernetes scan executed successfully" 1
fi

if [ "$DOCKER_STATUS" -eq 0 ]; then
    record_result "Framework filter: Dockerfile scan executed successfully" 0
else
    record_result "Framework filter: Dockerfile scan executed successfully" 1
fi

# ------------------------------------------------------------------------------
# Step 5: Validate Compliance Scorecard CLI & Markdown Export
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 5/6] Validating compliance_scorecard.py CLI and Markdown output...${CLR_RESET}"

set +e
python3 compliance_scorecard.py \
    --json-report reports/vulnerable_checkov_report.json \
    --sarif-report reports/vulnerable_checkov_report.sarif \
    --target-name "vulnerable_test" \
    --markdown-out reports/test_scorecard.md >/dev/null 2>&1
SCORECARD_STATUS=$?
set -e

if [ "$SCORECARD_STATUS" -eq 0 ]; then
    record_result "compliance_scorecard.py successfully parsed JSON & SARIF reports" 0
else
    record_result "compliance_scorecard.py successfully parsed JSON & SARIF reports" 1
fi

if [ -f "reports/test_scorecard.md" ] && grep -q "Compliance Overview Matrix" "reports/test_scorecard.md"; then
    record_result "Executive Markdown scorecard contains structured compliance matrix" 0
else
    record_result "Executive Markdown scorecard contains structured compliance matrix" 1
fi

# ------------------------------------------------------------------------------
# Step 6: Strict Policy Enforcement Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 6/6] Validating strict mode gate enforcement...${CLR_RESET}"

set +e
python3 compliance_scorecard.py --json-report reports/vulnerable_checkov_report.json --strict >/dev/null 2>&1
STRICT_VULN_STATUS=$?

python3 compliance_scorecard.py --json-report reports/remediated_checkov_report.json --strict >/dev/null 2>&1
STRICT_REMED_STATUS=$?
set -e

if [ "$STRICT_VULN_STATUS" -ne 0 ]; then
    record_result "compliance_scorecard.py strict mode correctly flags violations with exit code 1" 0
else
    record_result "compliance_scorecard.py strict mode correctly flags violations" 1
fi

if [ "$STRICT_REMED_STATUS" -eq 0 ]; then
    record_result "compliance_scorecard.py strict mode passes clean infrastructure with exit code 0" 0
else
    record_result "compliance_scorecard.py strict mode passes clean infrastructure" 1
fi

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  📊 TEST SUITE SUMMARY"
echo "======================================================================${CLR_RESET}"
echo -e "  Total Tests Evaluated : ${TOTAL_TESTS}"
echo -e "  Passed                : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed                : ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL IaC SECURITY SCANNING TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. REVIEW LOGS ABOVE.${CLR_RESET}\n"
    exit 1
fi
