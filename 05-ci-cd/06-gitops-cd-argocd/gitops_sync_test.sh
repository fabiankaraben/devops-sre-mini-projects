#!/usr/bin/env bash
# ==============================================================================
# gitops_sync_test.sh - End-to-End ArgoCD GitOps Reconciliation Test Suite
# ==============================================================================
# Test Phases:
#   1. Environment & ArgoCD Health Verification
#   2. Baseline Sync & Health Status Check (Phase 1)
#   3. GitOps Commit Simulation (Version bump to v2.0.0, replicas 2 -> 3)
#   4. Reconciliation Latency Measurement & Sync Verification (SLO: < 60s)
#   5. Cluster Drift Injection & Automated Self-Healing Verification
#   6. Workload Integrity & HTTP Probe Test
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
RESULTS_FILE="${SANDBOX_DIR}/test-results.json"
ARGOCD_NS="argocd"
GIT_NS="gitops-system"
APP_NS="gitops-demo"
APP_NAME="gitops-webapp"
SLO_TARGET_SEC=60
POLL_INTERVAL=2

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

mkdir -p "$SANDBOX_DIR"

show_help() {
    cat <<EOF
Usage: ./gitops_sync_test.sh [OPTIONS]

Executes the automated GitOps reconciliation and drift self-healing test suite.

Options:
  --slo <seconds>         Maximum allowable sync time in seconds (default: ${SLO_TARGET_SEC})
  --validate-only         Validate manifests and syntax without interacting with cluster
  -h, --help              Display this help message

Examples:
  ./gitops_sync_test.sh           # Run standard GitOps continuous delivery verification
  ./gitops_sync_test.sh --slo 45  # Run verification enforcing 45s reconciliation SLO
EOF
}

VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slo)
            SLO_TARGET_SEC="$2"
            shift 2
            ;;
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

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
echo "  🧪 ArgoCD GitOps Continuous Delivery & Self-Healing Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Offline / Validation Only Mode
if [[ "$VALIDATE_ONLY" == true ]]; then
    echo -e "${CLR_YELLOW}▶ Running in Validation-Only Mode (Offline Manifest & Syntax Check)...${CLR_RESET}"
    
    # 1. Check kustomize config_repo
    if kubectl kustomize "${SCRIPT_DIR}/config_repo" >/dev/null 2>&1; then
        record_test_result "Kustomize Config Repository Manifests" "PASS" "Kustomize build succeeded with valid YAML"
    else
        record_test_result "Kustomize Config Repository Manifests" "FAIL" "Kustomize validation failed"
    fi

    # 2. Check ArgoCD Application CRD manifest structure
    if grep -q "kind: Application" "${SCRIPT_DIR}/argocd_app.yaml" && \
       grep -q "repoURL:" "${SCRIPT_DIR}/argocd_app.yaml" && \
       grep -q "destination:" "${SCRIPT_DIR}/argocd_app.yaml" && \
       grep -q "selfHeal: true" "${SCRIPT_DIR}/argocd_app.yaml"; then
        record_test_result "ArgoCD Application CRD Manifest" "PASS" "Valid GitOps Application schema & sync policy"
    else
        record_test_result "ArgoCD Application CRD Manifest" "FAIL" "Missing required Application fields in argocd_app.yaml"
    fi

    # 3. Check Git Server manifest syntax
    if kubectl kustomize "${SCRIPT_DIR}/git-server" >/dev/null 2>&1; then
        record_test_result "In-Cluster Git Server Manifest" "PASS" "Valid Namespace, ConfigMap, Deployment & Service specs"
    else
        record_test_result "In-Cluster Git Server Manifest" "FAIL" "Git server manifest validation failed"
    fi

    echo -e "\n${CLR_CYAN}Validation Summary: ${PASSED_TESTS}/${TOTAL_TESTS} passed.${CLR_RESET}"
    exit 0
fi

# ==============================================================================
# Phase 1: Environment & ArgoCD Health Verification
# ==============================================================================
echo -e "${CLR_YELLOW}▶ [Phase 1/5] Checking Kubernetes Cluster & ArgoCD Status...${CLR_RESET}"

if ! kubectl get nodes >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Cannot connect to Kubernetes cluster." >&2
    echo "  Please run './setup_gitops_cluster.sh' first to provision the environment." >&2
    exit 1
fi
record_test_result "Kubernetes Cluster Connectivity" "PASS" "Node(s) responsive"

# Check ArgoCD Application Controller
CONTROLLER_READY=$(kubectl get pods -n "$ARGOCD_NS" -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
if [[ "$CONTROLLER_READY" == "true" ]]; then
    record_test_result "ArgoCD Application Controller" "PASS" "Pod is Ready"
else
    record_test_result "ArgoCD Application Controller" "FAIL" "Controller not ready in namespace ${ARGOCD_NS}"
fi

# Check Git Server Pod
GIT_SERVER_READY=$(kubectl get pods -n "$GIT_NS" -l app.kubernetes.io/name=git-server -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
if [[ "$GIT_SERVER_READY" == "true" ]]; then
    record_test_result "In-Cluster Git Server" "PASS" "Git repository service responsive"
else
    record_test_result "In-Cluster Git Server" "FAIL" "Git server pod not ready in namespace ${GIT_NS}"
fi

# Check Application CRD exists
if kubectl -n "$ARGOCD_NS" get application "$APP_NAME" >/dev/null 2>&1; then
    record_test_result "ArgoCD Application CRD (${APP_NAME})" "PASS" "Application registered"
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Application ${APP_NAME} not found. Applying ${SCRIPT_DIR}/argocd_app.yaml..."
    kubectl apply -f "${SCRIPT_DIR}/argocd_app.yaml"
    record_test_result "ArgoCD Application CRD Registration" "PASS" "Manifest applied"
fi

# ==============================================================================
# Phase 2: Baseline Sync & Initial Health Check
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 2/5] Verifying Baseline Deployment & Sync State...${CLR_RESET}"

# Reset in-cluster Git repo to baseline seed manifests (ensures idempotency)
GIT_POD=$(kubectl -n "$GIT_NS" get pods -l app.kubernetes.io/name=git-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$GIT_NS" "$GIT_POD" -c git-server -- /bin/sh -c "
    cd /tmp/seed
    cp /seed-manifests/* /tmp/seed/
    git add .
    if ! git diff-index --quiet HEAD --; then
        git commit -m 'chore(reset): restore baseline v1.0.0 manifests'
        git push origin main
    fi
" >/dev/null 2>&1 || true

# Force refresh to ensure ArgoCD observes baseline revision
kubectl -n "$ARGOCD_NS" annotate application "$APP_NAME" argocd.argoproj.io/refresh="hard" --overwrite >/dev/null 2>&1 || true

echo "  Waiting for ArgoCD baseline synchronization (v1.0.0, 2 replicas)..."
INITIAL_SYNCED=false
for ((i=1; i<=30; i++)); do
    SYNC_STATUS=$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    REPLICAS=$(kubectl -n "$APP_NS" get deployment "$APP_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    IMAGE=$(kubectl -n "$APP_NS" get deployment "$APP_NAME" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "none")
    VERSION=$(kubectl -n "$APP_NS" get configmap gitops-webapp-config -o jsonpath='{.data.APP_VERSION}' 2>/dev/null || echo "none")

    if [[ "$SYNC_STATUS" == "Synced" && "$HEALTH_STATUS" == "Healthy" && "$REPLICAS" -eq 2 && "$VERSION" == "v1.0.0" ]]; then
        INITIAL_SYNCED=true
        break
    elif [[ "$SYNC_STATUS" == "OutOfSync" ]]; then
        kubectl -n "$ARGOCD_NS" patch application "$APP_NAME" --type merge -p '{"operation":{"sync":{"prune":true}}}' >/dev/null 2>&1 || true
    fi
    sleep "$POLL_INTERVAL"
done

if [[ "$INITIAL_SYNCED" == true ]]; then
    record_test_result "Baseline GitOps State" "PASS" "Status: ${SYNC_STATUS} | Health: ${HEALTH_STATUS}"
    record_test_result "Baseline Workload Verification" "PASS" "Replicas: ${REPLICAS}, Version: ${VERSION}, Image: ${IMAGE}"
else
    record_test_result "Baseline GitOps State" "FAIL" "Status: ${SYNC_STATUS} | Health: ${HEALTH_STATUS}"
    record_test_result "Baseline Workload Verification" "FAIL" "Replicas: ${REPLICAS} (expected 2), Version: ${VERSION} (expected v1.0.0)"
fi

# ==============================================================================
# Phase 3 & 4: GitOps Commit Simulation & Reconciliation Speed Benchmark
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 3/5] Simulating GitOps Commit: Updating Application to v2.0.0 & Scaling to 3 Replicas...${CLR_RESET}"

GIT_POD=$(kubectl -n "$GIT_NS" get pods -l app.kubernetes.io/name=git-server -o jsonpath='{.items[0].metadata.name}')

echo "  Committing configuration update into Git repository inside ${GIT_POD}..."
NEW_COMMIT_MSG="feat(release): upgrade webapp to v2.0.0 and scale replicas to 3"

# Update deployment replicas to 3 and configmap version to v2.0.0 directly in the Git repository
kubectl exec -n "$GIT_NS" "$GIT_POD" -c git-server -- /bin/sh -c "
    cd /tmp/seed
    sed -i 's/APP_VERSION: \"v1.0.0\"/APP_VERSION: \"v2.0.0\"/g' configmap.yaml
    sed -i 's/replicas: 2/replicas: 3/g' deployment.yaml
    sed -i 's/version: \"1.0.0\"/version: \"2.0.0\"/g' deployment.yaml
    git add configmap.yaml deployment.yaml
    git commit -m '${NEW_COMMIT_MSG}'
    git push origin main
" >/dev/null 2>&1

NEW_COMMIT_SHA=$(kubectl exec -n "$GIT_NS" "$GIT_POD" -c git-server -- git --git-dir=/git/repo.git rev-parse main | tr -d '[:space:]')
SHORT_SHA="${NEW_COMMIT_SHA:0:7}"
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Git commit pushed: ${CLR_BOLD}${SHORT_SHA}${CLR_RESET} (${NEW_COMMIT_MSG})"

echo -e "\n${CLR_YELLOW}▶ [Phase 4/5] Measuring ArgoCD Reconciliation Latency (SLO: < ${SLO_TARGET_SEC}s)...${CLR_RESET}"

START_TIME=$(date +%s)
RECONCILED=false
RECONCILE_DURATION=0

# Force ArgoCD to check repo revision immediately (simulating webhook notification)
kubectl -n "$ARGOCD_NS" annotate application "$APP_NAME" argocd.argoproj.io/refresh="hard" --overwrite >/dev/null 2>&1 || true

echo "  Monitoring ArgoCD sync state transition..."
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    CURRENT_SYNC=$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    CURRENT_HEALTH=$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    DEPLOYED_REPLICAS=$(kubectl -n "$APP_NS" get deployment "$APP_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    DEPLOYED_VERSION=$(kubectl -n "$APP_NS" get configmap gitops-webapp-config -o jsonpath='{.data.APP_VERSION}' 2>/dev/null || echo "none")

    echo -ne "  [Elapsed: ${ELAPSED}s] Sync: ${CURRENT_SYNC} | Health: ${CURRENT_HEALTH} | Replicas: ${DEPLOYED_REPLICAS} | Version: ${DEPLOYED_VERSION}\r"

    if [[ "$CURRENT_SYNC" == "Synced" && "$CURRENT_HEALTH" == "Healthy" && "$DEPLOYED_REPLICAS" -eq 3 && "$DEPLOYED_VERSION" == "v2.0.0" ]]; then
        RECONCILED=true
        RECONCILE_DURATION="$ELAPSED"
        echo ""
        break
    fi

    if [[ "$ELAPSED" -ge "$SLO_TARGET_SEC" ]]; then
        echo ""
        break
    fi

    sleep "$POLL_INTERVAL"
done

if [[ "$RECONCILED" == true && "$RECONCILE_DURATION" -le "$SLO_TARGET_SEC" ]]; then
    record_test_result "GitOps Continuous Delivery Reconciliation" "PASS" "Reconciled in ${RECONCILE_DURATION}s (SLO target: <= ${SLO_TARGET_SEC}s)"
else
    record_test_result "GitOps Continuous Delivery Reconciliation" "FAIL" "Failed to reconcile within ${SLO_TARGET_SEC}s (Elapsed: ${ELAPSED}s)"
fi

# ==============================================================================
# Phase 5: Cluster Drift Injection & Automated Self-Healing
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 5/5] Testing Cluster Drift Detection & Self-Healing (${CLR_BOLD}selfHeal: true${CLR_RESET}${CLR_YELLOW})...${CLR_RESET}"

echo "  [Drift Injection] Manually scaling live deployment in cluster to 1 replica (violating Git desired state of 3)..."
kubectl -n "$APP_NS" scale deployment "$APP_NAME" --replicas=1 >/dev/null 2>&1

DRIFT_REPLICAS=$(kubectl -n "$APP_NS" get deployment "$APP_NAME" -o jsonpath='{.spec.replicas}')
echo "  Live deployment scale set directly via kubectl: ${DRIFT_REPLICAS}"

echo "  Waiting for ArgoCD self-healing loop to detect drift and restore Git desired state..."
SELF_HEALED=false
DRIFT_START_TIME=$(date +%s)
DRIFT_DURATION=0

# Prompt controller refresh to trigger instant reconciliation loop
kubectl -n "$ARGOCD_NS" annotate application "$APP_NAME" argocd.argoproj.io/refresh="normal" --overwrite >/dev/null 2>&1 || true

for ((i=1; i<=30; i++)); do
    CURRENT_TIME=$(date +%s)
    DRIFT_ELAPSED=$((CURRENT_TIME - DRIFT_START_TIME))
    RESTORED_REPLICAS=$(kubectl -n "$APP_NS" get deployment "$APP_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    if [[ "$RESTORED_REPLICAS" -eq 3 ]]; then
        SELF_HEALED=true
        DRIFT_DURATION="$DRIFT_ELAPSED"
        break
    fi
    sleep "$POLL_INTERVAL"
done

if [[ "$SELF_HEALED" == true ]]; then
    record_test_result "Automated Drift Self-Healing" "PASS" "Restored replicas 1 -> 3 in ${DRIFT_DURATION}s without human intervention"
    echo "  Waiting for restored replica pods to transition to Ready..."
    kubectl rollout status deployment "$APP_NAME" -n "$APP_NS" --timeout=30s >/dev/null 2>&1 || true
else
    record_test_result "Automated Drift Self-Healing" "FAIL" "Replicas remained at ${RESTORED_REPLICAS} (expected auto-healing to 3)"
fi

# Workload Pod Integrity Check
READY_PODS=$(kubectl -n "$APP_NS" get deployment "$APP_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$READY_PODS" -ge 3 ]]; then
    record_test_result "Target Microservice Pod Health" "PASS" "${READY_PODS}/3 pods Ready in namespace ${APP_NS}"
else
    record_test_result "Target Microservice Pod Health" "FAIL" "${READY_PODS}/3 pods Ready"
fi

# ==============================================================================
# Phase 6: HTTP Live Endpoint Health Probe
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Verification] Probing Live Microservice Endpoint over HTTP...${CLR_RESET}"
PF_PORT=18082
kubectl port-forward -n "$APP_NS" "svc/${APP_NAME}" "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
sleep 2

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${PF_PORT}/" || echo "000")
kill "$PF_PID" >/dev/null 2>&1 || true
wait "$PF_PID" 2>/dev/null || true

if [[ "$HTTP_STATUS" == "200" ]]; then
    record_test_result "Application HTTP Endpoint Probe" "PASS" "HTTP ${HTTP_STATUS} OK returned from cluster Service"
else
    record_test_result "Application HTTP Endpoint Probe" "FAIL" "HTTP status code: ${HTTP_STATUS} (expected 200)"
fi

# ==============================================================================
# Summary Report & JSON Output
# ==============================================================================
cat <<EOF > "$RESULTS_FILE"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "total_tests": ${TOTAL_TESTS},
  "passed_tests": ${PASSED_TESTS},
  "failed_tests": ${FAILED_TESTS},
  "reconciliation_time_seconds": ${RECONCILE_DURATION},
  "slo_target_seconds": ${SLO_TARGET_SEC},
  "drift_recovery_time_seconds": ${DRIFT_DURATION},
  "git_commit_sha": "${NEW_COMMIT_SHA}",
  "sync_status": "${CURRENT_SYNC}",
  "health_status": "${CURRENT_HEALTH}",
  "deployed_version": "${DEPLOYED_VERSION}",
  "deployed_replicas": ${DEPLOYED_REPLICAS}
}
EOF

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 ArgoCD GitOps Verification Summary Report${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Total Test Steps:       ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  • Tests Passed:           ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
echo -e "  • Tests Failed:           ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
echo -e "  • GitOps Sync Latency:    ${CLR_MAGENTA}${CLR_BOLD}${RECONCILE_DURATION}s${CLR_RESET} (SLO Target: < ${SLO_TARGET_SEC}s)"
echo -e "  • Drift Recovery Latency: ${CLR_MAGENTA}${CLR_BOLD}${DRIFT_DURATION}s${CLR_RESET}"
echo -e "  • Active Version:         ${CLR_CYAN}${DEPLOYED_VERSION}${CLR_RESET}"
echo -e "  • Active Pod Replicas:    ${CLR_CYAN}${DEPLOYED_REPLICAS}${CLR_RESET}"
echo -e "  • Detailed JSON Report:   ${CLR_GRAY}${RESULTS_FILE}${CLR_RESET}"
echo "======================================================================"

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ ALL GITOPS PIPELINE TESTS PASSED SUCCESSFULLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ GITOPS TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S).${CLR_RESET}\n"
    exit 1
fi
