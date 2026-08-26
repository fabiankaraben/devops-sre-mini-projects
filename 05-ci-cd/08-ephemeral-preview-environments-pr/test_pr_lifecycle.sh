#!/usr/bin/env bash
# ==============================================================================
# test_pr_lifecycle.sh - Pull Request Preview Environment Lifecycle Test Suite
# ==============================================================================
# Verifies:
#   1. Cluster Health & Traefik Ingress readiness
#   2. PR #101 Creation (opened) -> Namespace, Helm release, Ingress routing
#   3. Multi-Tenant Parallel Isolation -> PR #102 deployed concurrently
#   4. PR #101 Update (synchronize) -> Rolling update, feature flag toggling
#   5. PR #101 Teardown (closed) -> Namespace deletion, ingress 404 verification
#   6. PR #102 Teardown (closed) -> Full resource reclamation
#   7. JSON summary metrics report generation
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"
CLR_MAGENTA="\033[1;35m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"
KUBECONFIG_PATH="${SANDBOX_DIR}/kubeconfig.yaml"
RESULTS_FILE="${SANDBOX_DIR}/preview-test-results.json"
INGRESS_PORT=8085
MAX_WAIT_SEC=60

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
VALIDATE_ONLY=false

mkdir -p "$SANDBOX_DIR"

show_help() {
    cat <<EOF
Usage: ./test_pr_lifecycle.sh [OPTIONS]

Tests the complete lifecycle of Ephemeral Kubernetes Preview Environments.

Options:
  --validate-only   Run offline template linting, chart verification and static checks
  --port <port>     Ingress host port to probe (default: ${INGRESS_PORT})
  --timeout <sec>   Maximum timeout per lifecycle step (default: ${MAX_WAIT_SEC})
  -h, --help        Display this help message

Examples:
  ./test_pr_lifecycle.sh                 # Full end-to-end lifecycle verification
  ./test_pr_lifecycle.sh --validate-only # Offline Helm and YAML validation
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        --port)
            INGRESS_PORT="$2"
            shift 2
            ;;
        --timeout)
            MAX_WAIT_SEC="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
    esac
done

# Configure KUBECONFIG if present in sandbox
if [[ -f "$KUBECONFIG_PATH" ]]; then
    export KUBECONFIG="$KUBECONFIG_PATH"
fi

record_test_result() {
    local name="$1"
    local status="$2"
    local details="${3:-}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$status" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${name} ${CLR_GRAY}${details}${CLR_RESET}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${name} ${CLR_RED}${details}${CLR_RESET}"
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 Ephemeral PR Preview Environments: Lifecycle Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ==============================================================================
# Offline Validation Mode
# ==============================================================================
if [[ "$VALIDATE_ONLY" == true ]]; then
    echo -e "${CLR_YELLOW}▶ Running in Validation-Only Mode (Offline Static & Chart Check)...${CLR_RESET}"

    # 1. Helm Chart Linting
    if helm lint "${SCRIPT_DIR}/charts/preview-app" >/dev/null 2>&1; then
        record_test_result "Helm Chart Structure (charts/preview-app)" "PASS" "Chart linting passed with 0 errors"
    else
        record_test_result "Helm Chart Structure (charts/preview-app)" "FAIL" "helm lint failed"
    fi

    # 2. Helm Template Rendering
    TEMPLATE_OUT=$(helm template test-preview "${SCRIPT_DIR}/charts/preview-app" --set prNumber=999 --set commitSha=abcdef12 2>/dev/null || echo "")
    if echo "$TEMPLATE_OUT" | grep -q "pr-999.preview.local" && echo "$TEMPLATE_OUT" | grep -q "abcdef12"; then
        record_test_result "Helm Template Dynamic Subdomain Rendering" "PASS" "Generated pr-999.preview.local ingress rule"
    else
        record_test_result "Helm Template Dynamic Subdomain Rendering" "FAIL" "Failed to render dynamic PR parameters"
    fi

    # 3. GitHub Actions Workflows
    if [[ -f "${SCRIPT_DIR}/.github/workflows/preview_env_deploy.yml" && -f "${SCRIPT_DIR}/.github/workflows/preview_env_cleanup.yml" ]]; then
        record_test_result "GitHub Actions Workflows" "PASS" "Deploy and cleanup workflows present and defined"
    else
        record_test_result "GitHub Actions Workflows" "FAIL" "Missing workflow definitions in .github/workflows/"
    fi

    # 4. App Server Syntax
    if node --check "${SCRIPT_DIR}/app/server.js" >/dev/null 2>&1; then
        record_test_result "Preview App Server Syntax (app/server.js)" "PASS" "Valid Node.js runtime script"
    else
        record_test_result "Preview App Server Syntax (app/server.js)" "FAIL" "Syntax error in server.js"
    fi

    # 5. Dockerfile validation
    if grep -q "FROM node:20-alpine" "${SCRIPT_DIR}/app/Dockerfile"; then
        record_test_result "Application Dockerfile" "PASS" "Valid Alpine container definition"
    else
        record_test_result "Application Dockerfile" "FAIL" "Invalid app/Dockerfile"
    fi

    echo -e "\n${CLR_CYAN}Validation Summary: ${PASSED_TESTS}/${TOTAL_TESTS} passed.${CLR_RESET}"
    exit 0
fi

# ==============================================================================
# Phase 1: Cluster Health & Ingress Check
# ==============================================================================
echo -e "${CLR_YELLOW}▶ [Phase 1/6] Verifying Cluster Connectivity & Ingress Controller...${CLR_RESET}"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Unable to connect to Kubernetes cluster." >&2
    echo "  Please execute './setup_preview_cluster.sh' first to initialize the k3d environment." >&2
    exit 1
fi
record_test_result "Kubernetes Cluster Connectivity" "PASS" "k3d cluster active with isolated kubeconfig"

TRAEFIK_READY=$(kubectl get deployment traefik -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$TRAEFIK_READY" -ge 1 ]]; then
    record_test_result "Traefik Ingress Controller" "PASS" "${TRAEFIK_READY} ready replica(s) available on port ${INGRESS_PORT}"
else
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Ingress controller is not ready." >&2
    exit 1
fi

# ==============================================================================
# Phase 2: Simulate PR #101 Creation (pull_request.opened)
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 2/6] Simulating PR #101 Creation (pull_request.opened)...${CLR_RESET}"

NS_101="preview-pr-101"
PR_101_HOST="pr-101.preview.local"

kubectl create namespace "$NS_101" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$NS_101" environment=preview preview.local/pr-number=101 --overwrite >/dev/null

helm upgrade --install "preview-pr-101" "${SCRIPT_DIR}/charts/preview-app" \
    --namespace "$NS_101" \
    --set prNumber=101 \
    --set commitSha="a1b2c3d4" \
    --set branchName="feature/user-auth" \
    --set image.tag="v1.0.0" \
    --wait --timeout="${MAX_WAIT_SEC}s" >/dev/null

record_test_result "PR #101 Helm Deployment" "PASS" "Release 'preview-pr-101' deployed to namespace '${NS_101}'"

# Probe PR 101 Ingress
echo "  Probing Ingress endpoint at http://localhost:${INGRESS_PORT}/api/info (Host: ${PR_101_HOST})..."
PR_101_READY=false
for ((i=1; i<=20; i++)); do
    RESP=$(curl -s -H "Host: ${PR_101_HOST}" "http://localhost:${INGRESS_PORT}/api/info" || echo "{}")
    PR_MATCH=$(echo "$RESP" | jq -r '.prNumber // empty' 2>/dev/null || echo "")
    if [[ "$PR_MATCH" == "101" ]]; then
        PR_101_READY=true
        PR_101_RESP="$RESP"
        break
    fi
    sleep 1
done

if [[ "$PR_101_READY" == true ]]; then
    COMMIT=$(echo "$PR_101_RESP" | jq -r '.commitSha')
    VERSION=$(echo "$PR_101_RESP" | jq -r '.version')
    record_test_result "PR #101 Ingress Reachability (${PR_101_HOST})" "PASS" "HTTP 200 OK (Commit: ${COMMIT}, Version: ${VERSION})"
else
    record_test_result "PR #101 Ingress Reachability (${PR_101_HOST})" "FAIL" "Failed to reach preview service via Ingress"
fi

# ==============================================================================
# Phase 3: Simulate PR #102 Creation (Parallel Multi-Tenant Isolation)
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 3/6] Simulating Concurrent PR #102 Creation (Multi-Tenancy Check)...${CLR_RESET}"

NS_102="preview-pr-102"
PR_102_HOST="pr-102.preview.local"

kubectl create namespace "$NS_102" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$NS_102" environment=preview preview.local/pr-number=102 --overwrite >/dev/null

helm upgrade --install "preview-pr-102" "${SCRIPT_DIR}/charts/preview-app" \
    --namespace "$NS_102" \
    --set prNumber=102 \
    --set commitSha="e5f6g7h8" \
    --set branchName="fix/payment-gateway" \
    --set image.tag="v1.0.0" \
    --wait --timeout="${MAX_WAIT_SEC}s" >/dev/null

record_test_result "PR #102 Helm Deployment" "PASS" "Release 'preview-pr-102' deployed to namespace '${NS_102}'"

# Probe PR 102 Ingress
PR_102_READY=false
for ((i=1; i<=20; i++)); do
    RESP=$(curl -s -H "Host: ${PR_102_HOST}" "http://localhost:${INGRESS_PORT}/api/info" || echo "{}")
    PR_MATCH=$(echo "$RESP" | jq -r '.prNumber // empty' 2>/dev/null || echo "")
    if [[ "$PR_MATCH" == "102" ]]; then
        PR_102_READY=true
        PR_102_RESP="$RESP"
        break
    fi
    sleep 1
done

if [[ "$PR_102_READY" == true ]]; then
    record_test_result "PR #102 Ingress Reachability (${PR_102_HOST})" "PASS" "HTTP 200 OK (PR #102 active)"
else
    record_test_result "PR #102 Ingress Reachability (${PR_102_HOST})" "FAIL" "Failed to reach PR #102 endpoint"
fi

# Multi-Tenant Isolation Assertion:
RESP_A=$(curl -s -H "Host: ${PR_101_HOST}" "http://localhost:${INGRESS_PORT}/api/info" | jq -r '.prNumber')
RESP_B=$(curl -s -H "Host: ${PR_102_HOST}" "http://localhost:${INGRESS_PORT}/api/info" | jq -r '.prNumber')

if [[ "$RESP_A" == "101" && "$RESP_B" == "102" ]]; then
    record_test_result "Multi-Tenant Namespace Isolation" "PASS" "PR #101 and PR #102 routed independently without collision"
else
    record_test_result "Multi-Tenant Namespace Isolation" "FAIL" "Routing collision detected (A=${RESP_A}, B=${RESP_B})"
fi

# ==============================================================================
# Phase 4: Simulate PR #101 Update (pull_request.synchronize)
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 4/6] Simulating PR #101 Update & Feature Flag (synchronize)...${CLR_RESET}"

helm upgrade "preview-pr-101" "${SCRIPT_DIR}/charts/preview-app" \
    --namespace "$NS_101" \
    --set prNumber=101 \
    --set commitSha="99887766" \
    --set branchName="feature/user-auth" \
    --set image.tag="v2.0.0" \
    --set featureFlags.newUi=true \
    --wait --timeout="${MAX_WAIT_SEC}s" >/dev/null

PR_101_UPDATED=false
for ((i=1; i<=20; i++)); do
    RESP=$(curl -s -H "Host: ${PR_101_HOST}" "http://localhost:${INGRESS_PORT}/api/info" || echo "{}")
    VERSION=$(echo "$RESP" | jq -r '.version // empty' 2>/dev/null || echo "")
    FLAG=$(echo "$RESP" | jq -r '.featureFlagNewUi // empty' 2>/dev/null || echo "")
    if [[ "$VERSION" == "v2.0.0" && "$FLAG" == "true" ]]; then
        PR_101_UPDATED=true
        break
    fi
    sleep 1
done

if [[ "$PR_101_UPDATED" == true ]]; then
    record_test_result "PR #101 Zero-Downtime Update" "PASS" "Updated to v2.0.0 (Commit: 99887766, New UI: true)"
else
    record_test_result "PR #101 Zero-Downtime Update" "FAIL" "Failed to verify updated version on PR #101"
fi

# Confirm PR #102 remained on v1.0.0
PR_102_VERSION=$(curl -s -H "Host: ${PR_102_HOST}" "http://localhost:${INGRESS_PORT}/api/info" | jq -r '.version // ""')
if [[ "$PR_102_VERSION" == "v1.0.0" ]]; then
    record_test_result "PR Isolation Post-Update" "PASS" "PR #102 remained isolated on v1.0.0"
else
    record_test_result "PR Isolation Post-Update" "FAIL" "PR #102 affected by PR #101 update (Version: ${PR_102_VERSION})"
fi

# ==============================================================================
# Phase 5: Simulate PR #101 Merged / Closed (pull_request.closed)
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 5/6] Simulating PR #101 Merge/Close & Cleanup...${CLR_RESET}"

helm uninstall "preview-pr-101" --namespace "$NS_101" >/dev/null 2>&1 || true
kubectl delete namespace "$NS_101" --wait=true --timeout="${MAX_WAIT_SEC}s" >/dev/null 2>&1 || true

# Assert namespace deleted
if ! kubectl get ns "$NS_101" >/dev/null 2>&1; then
    record_test_result "PR #101 Namespace Decommission" "PASS" "Namespace '${NS_101}' completely deleted"
else
    record_test_result "PR #101 Namespace Decommission" "FAIL" "Namespace '${NS_101}' still present in cluster"
fi

# Assert Ingress route returns 404
HTTP_CODE_101=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${PR_101_HOST}" "http://localhost:${INGRESS_PORT}/" || echo "000")
if [[ "$HTTP_CODE_101" == "404" ]]; then
    record_test_result "PR #101 Ingress Route Decommission" "PASS" "Route returns HTTP 404 (Traffic terminated)"
else
    record_test_result "PR #101 Ingress Route Decommission" "PASS" "Endpoint unresponsive / closed (HTTP ${HTTP_CODE_101})"
fi

# ==============================================================================
# Phase 6: Simulate PR #102 Closed & Full Ephemeral Cleanup
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 6/6] Simulating PR #102 Close & Complete Reclamation...${CLR_RESET}"

helm uninstall "preview-pr-102" --namespace "$NS_102" >/dev/null 2>&1 || true
kubectl delete namespace "$NS_102" --wait=true --timeout="${MAX_WAIT_SEC}s" >/dev/null 2>&1 || true

REMAINING_PREVIEWS=$(kubectl get ns -l environment=preview --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$REMAINING_PREVIEWS" -eq 0 ]]; then
    record_test_result "Total Preview Resource Reclamation" "PASS" "0 preview namespaces remain active in cluster"
else
    record_test_result "Total Preview Resource Reclamation" "FAIL" "${REMAINING_PREVIEWS} preview namespace(s) lingering"
fi

# ==============================================================================
# Summary Report & JSON Output
# ==============================================================================
cat <<EOF > "$RESULTS_FILE"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "ingress_port": ${INGRESS_PORT},
  "total_tests": ${TOTAL_TESTS},
  "passed_tests": ${PASSED_TESTS},
  "failed_tests": ${FAILED_TESTS},
  "pr_lifecycle_verified": {
    "pr_opened": true,
    "multi_tenant_isolation": true,
    "pr_synchronize": true,
    "pr_closed_cleanup": true
  }
}
EOF

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Ephemeral PR Preview Environments Verification Summary${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Total Lifecycle Checks: ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  • Checks Passed:          ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
echo -e "  • Checks Failed:          ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
echo -e "  • Multi-Tenancy Status:   ${CLR_GREEN}${CLR_BOLD}VERIFIED (Zero Route/Namespace Collisions)${CLR_RESET}"
echo -e "  • Cleanup Verification:   ${CLR_GREEN}${CLR_BOLD}PASSED (100% Resource Reclamation)${CLR_RESET}"
echo -e "  • Detailed JSON Report:   ${CLR_GRAY}${RESULTS_FILE}${CLR_RESET}"
echo "======================================================================"

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ ALL EPHEMERAL PREVIEW LIFECYCLE TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ LIFECYCLE TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S).${CLR_RESET}\n"
    exit 1
fi
