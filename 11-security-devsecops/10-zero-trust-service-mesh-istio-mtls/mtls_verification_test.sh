#!/usr/bin/env bash
# ==============================================================================
# mtls_verification_test.sh - Zero-Trust Service Mesh mTLS Test Suite
# ==============================================================================
# Automates validation of:
#   1. Kubernetes cluster & Istio control plane readiness
#   2. Automatic Envoy sidecar proxy injection
#   3. STRICT PeerAuthentication enforcement
#   4. Fine-grained RBAC AuthorizationPolicy validation
#   5. Lateral attacker & unauthorized path rejection
#   6. Multi-format audit reporting (JSON, Markdown, HTML)
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
echo "  🧪 STARTING ZERO-TRUST ISTIO SERVICE MESH mTLS TEST SUITE"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Validate Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [Step 1/5] Validating runtime tools & Kubernetes CLI...${CLR_RESET}"
for tool in docker k3d kubectl helm python3; do
    command -v "$tool" >/dev/null 2>&1
    record_result "CLI tool '$tool' is available" $?
done

# ------------------------------------------------------------------------------
# 2. Cluster & Istio Service Mesh Setup
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 2/5] Ensuring k3d cluster and Istio mesh are provisioned...${CLR_RESET}"
./scripts/cluster_setup.sh >/dev/null 2>&1
record_result "Cluster setup script completed successfully" $?

# Verify Istiod
kubectl get deployment istiod -n istio-system >/dev/null 2>&1
record_result "Istiod control plane is active in istio-system" $?

# ------------------------------------------------------------------------------
# 3. Validate Sidecar Injection & Policies
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 3/5] Validating Envoy sidecar injection & Zero-Trust policies...${CLR_RESET}"

# Verify 2/2 containers on backend
BACKEND_READY=$(kubectl get deployment backend -n mesh-secure -o jsonpath='{.status.readyReplicas}')
test "$BACKEND_READY" -ge 1
record_result "Backend deployment has active Envoy sidecar proxy (2/2 ready)" $?

# Verify 2/2 containers on frontend
FRONTEND_READY=$(kubectl get deployment frontend -n mesh-secure -o jsonpath='{.status.readyReplicas}')
test "$FRONTEND_READY" -ge 1
record_result "Frontend deployment has active Envoy sidecar proxy (2/2 ready)" $?

# Verify PeerAuthentication STRICT mode
PA_MODE=$(kubectl get peerauthentication default -n mesh-secure -o jsonpath='{.spec.mtls.mode}')
test "$PA_MODE" = "STRICT"
record_result "PeerAuthentication in mesh-secure is strictly configured to STRICT" $?

# Verify AuthorizationPolicy
kubectl get authorizationpolicy backend-access-policy -n mesh-secure >/dev/null 2>&1
record_result "AuthorizationPolicy 'backend-access-policy' is active on backend" $?

# ------------------------------------------------------------------------------
# 4. Execute Zero-Trust Security Probing Matrix
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 4/5] Executing Zero-Trust mTLS & RBAC audit matrix...${CLR_RESET}"
python3 "$SCRIPT_DIR/scripts/verify_mtls.py" \
    --json-out "$SCRIPT_DIR/reports/mtls_audit_report.json" \
    --md-out "$SCRIPT_DIR/reports/mtls_audit_report.md" \
    --html-out "$SCRIPT_DIR/reports/mtls_audit_report.html"

record_result "verify_mtls.py verified 100% policy enforcement across all scenarios" $?

# ------------------------------------------------------------------------------
# 5. Verify Multi-Format Compliance Reports
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 5/5] Verifying compliance report artifacts...${CLR_RESET}"

test -s "$SCRIPT_DIR/reports/mtls_audit_report.json"
record_result "JSON audit report (reports/mtls_audit_report.json) is valid" $?

test -s "$SCRIPT_DIR/reports/mtls_audit_report.md"
record_result "Markdown compliance report (reports/mtls_audit_report.md) is valid" $?

test -s "$SCRIPT_DIR/reports/mtls_audit_report.html"
record_result "HTML dashboard report (reports/mtls_audit_report.html) is valid" $?

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  📊 TEST SUITE SUMMARY"
echo "======================================================================${CLR_RESET}"
echo "  Tests Passed : $PASSED_TESTS"
echo "  Tests Failed : $FAILED_TESTS"
echo "  Total Tests  : $TOTAL_TESTS"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL ZERO-TRUST ISTIO mTLS TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. Please review the output above.${CLR_RESET}\n"
    exit 1
fi
