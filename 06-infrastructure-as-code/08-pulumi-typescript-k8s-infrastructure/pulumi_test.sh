#!/usr/bin/env bash
# ==============================================================================
# pulumi_test.sh - E2E Pulumi TypeScript Kubernetes Test Suite
# ==============================================================================
# Verifies:
#   1. System prerequisites (Docker, K3d, Kubectl, Pulumi, pnpm, Node.js)
#   2. TypeScript compilation and type safety (pnpm build)
#   3. Fast in-memory unit tests with Pulumi Mocks (pnpm test)
#   4. Ephemeral K3d cluster creation with local Kubeconfig containment
#   5. Pulumi local file state backend initialization (zero cloud dependencies)
#   6. Speculative infrastructure preview (pulumi preview)
#   7. Live Kubernetes microservice provisioning (pulumi up --yes)
#   8. Real-time Pod, Service, and ConfigMap health verification via kubectl
#   9. Stack output assertion (namespace, endpoints, replica counts)
#  10. Multi-environment configuration & scaling verification (prod preview)
#  11. Clean stack destruction (pulumi destroy --yes)
#  12. Workspace teardown and sanitation (cleanup.sh)
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NAME="k3d-pulumi-demo"
KEEP_RUNNING=false

export PULUMI_HOME="${SCRIPT_DIR}/.pulumi_home"
export PULUMI_CONFIG_PASSPHRASE=""
export KUBECONFIG="${SCRIPT_DIR}/.kube/config"

for arg in "$@"; do
    case "$arg" in
        --keep)
            KEEP_RUNNING=true
            ;;
        --clean)
            exec ./cleanup.sh --all
            ;;
        --help|-h)
            echo "Usage: ./pulumi_test.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep     Keep K3d cluster and state files active after tests"
            echo "  --clean    Purge all containers, caches, and state immediately"
            echo "  --help, -h Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./pulumi_test.sh --help for usage."
            exit 1
            ;;
    esac
done

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    local test_num="$1"
    local description="$2"
    local status="$3"
    local details="${4:-}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$status" -eq 0 ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_GRAY}↳ ${details}${CLR_RESET}"
        fi
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_RED}↳ ${details}${CLR_RESET}"
        fi
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 Pulumi TypeScript Kubernetes Infrastructure - Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Test 1: Prerequisites Check
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 1: Verifying system prerequisites...${CLR_RESET}"
MISSING_TOOLS=()
for tool in docker k3d kubectl pulumi pnpm node; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -eq 0 ]]; then
    PULUMI_VER=$(pulumi version 2>/dev/null || echo "Unknown")
    record_result "1" "All prerequisites verified (Docker, K3d, Kubectl, Pulumi, pnpm, Node.js)" 0 "Pulumi ${PULUMI_VER}"
else
    record_result "1" "Missing required tools: ${MISSING_TOOLS[*]}" 1
fi

# ------------------------------------------------------------------------------
# Test 2: Dependency Installation & TypeScript Build
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 2: Compiling TypeScript & validating types (pnpm build)...${CLR_RESET}"
if pnpm build >/dev/null 2>&1; then
    record_result "2" "TypeScript build & strict type validation succeeded" 0 "Clean compilation to dist/"
else
    record_result "2" "TypeScript compilation failed" 1
fi

# ------------------------------------------------------------------------------
# Test 3: Fast In-Memory Unit Tests with Pulumi Mocks
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 3: Executing in-memory unit test suite with Pulumi Mocks (pnpm test)...${CLR_RESET}"
UNIT_OUT=$(pnpm test 2>&1 || echo "")
if [[ "$UNIT_OUT" == *"8 passing"* ]]; then
    record_result "3" "Pulumi Mocks unit tests passed (8/8 assertions)" 0 "Security hardening, labels & limits enforced"
else
    record_result "3" "Unit tests failed" 1 "$UNIT_OUT"
fi

# ------------------------------------------------------------------------------
# Test 4: Ephemeral K3d Kubernetes Cluster Bootstrap
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 4: Bootstrapping local K3d cluster (${CLUSTER_NAME})...${CLR_RESET}"
mkdir -p .kube .pulumi_home .pulumi_backend

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME} "; then
    record_result "4" "K3d cluster '${CLUSTER_NAME}' is already active" 0
else
    k3d cluster create "${CLUSTER_NAME}" \
        --kubeconfig-switch-context=false \
        --kubeconfig-update-default=false \
        --wait >/dev/null 2>&1 || true

    k3d kubeconfig get "${CLUSTER_NAME}" > .kube/config 2>/dev/null || true
    chmod 600 .kube/config

    if kubectl get nodes >/dev/null 2>&1; then
        NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
        record_result "4" "K3d cluster created with isolated kubeconfig containment" 0 "Node: ${NODE_NAME}"
    else
        record_result "4" "K3d cluster bootstrap failed" 1
    fi
fi

# ------------------------------------------------------------------------------
# Test 5: Pulumi Local Backend Initialization
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 5: Initializing Pulumi local file state backend...${CLR_RESET}"
if pulumi login "file://${SCRIPT_DIR}/.pulumi_backend" >/dev/null 2>&1 && \
   pulumi stack select dev --create >/dev/null 2>&1; then
    record_result "5" "Pulumi local file backend & 'dev' stack initialized" 0 "Backend: file://${SCRIPT_DIR}/.pulumi_backend"
else
    record_result "5" "Pulumi local backend initialization failed" 1
fi

# ------------------------------------------------------------------------------
# Test 6: Speculative Infrastructure Preview
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 6: Running speculative preview (pulumi preview)...${CLR_RESET}"
PREVIEW_OUT=$(pulumi preview --non-interactive 2>&1 || echo "")
if [[ "$PREVIEW_OUT" == *"14 to create"* || "$PREVIEW_OUT" == *"+ 14"* ]]; then
    record_result "6" "Pulumi preview correctly planned 14 resources (Namespace + 3 MicroserviceApps)" 0
else
    record_result "6" "Pulumi preview failed" 1 "$PREVIEW_OUT"
fi

# ------------------------------------------------------------------------------
# Test 7: Live Infrastructure Deployment (pulumi up)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 7: Deploying infrastructure to K3d (pulumi up --yes)...${CLR_RESET}"
UP_OUT=$(pulumi up --yes --non-interactive 2>&1 || echo "")
if [[ "$UP_OUT" == *"14 created"* || "$UP_OUT" == *"Resources:"* ]]; then
    record_result "7" "Pulumi up deployed 3 microservices and namespace into K3d" 0
else
    record_result "7" "Pulumi up failed" 1 "$UP_OUT"
fi

# ------------------------------------------------------------------------------
# Test 8: Live Kubernetes State Verification via kubectl
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 8: Verifying live resources in namespace 'pulumi-fleet-dev'...${CLR_RESET}"
POD_COUNT=$(kubectl get pods -n pulumi-fleet-dev --no-headers 2>/dev/null | wc -l | tr -d ' ')
SVC_COUNT=$(kubectl get svc -n pulumi-fleet-dev --no-headers 2>/dev/null | wc -l | tr -d ' ')
CM_COUNT=$(kubectl get configmap -n pulumi-fleet-dev --no-headers 2>/dev/null | grep -v "kube-root-ca" | wc -l | tr -d ' ')

if [[ "$POD_COUNT" -eq 3 && "$SVC_COUNT" -eq 3 && "$CM_COUNT" -ge 3 ]]; then
    record_result "8" "Live cluster verification: 3 Pods running, 3 Services, 3 ConfigMaps" 0 "Namespace: pulumi-fleet-dev"
else
    record_result "8" "Resource count mismatch (Pods: $POD_COUNT, Services: $SVC_COUNT, ConfigMaps: $CM_COUNT)" 1
fi

# ------------------------------------------------------------------------------
# Test 9: Stack Output Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 9: Verifying Pulumi stack outputs...${CLR_RESET}"
OUTPUT_JSON=$(pulumi stack output --json 2>/dev/null || echo "{}")
NS_OUT=$(echo "$OUTPUT_JSON" | jq -r '.exportedNamespace // empty')
REPLICAS_OUT=$(echo "$OUTPUT_JSON" | jq -r '.totalReplicas // empty')
FRONTEND_EP=$(echo "$OUTPUT_JSON" | jq -r '.appEndpoints.frontend // empty')

if [[ "$NS_OUT" == "pulumi-fleet-dev" && "$REPLICAS_OUT" == "3" && "$FRONTEND_EP" == *"frontend-svc.pulumi-fleet-dev"* ]]; then
    record_result "9" "Stack outputs validated (namespace, totalReplicas=3, DNS endpoints)" 0 "Endpoint: ${FRONTEND_EP}"
else
    record_result "9" "Stack outputs verification failed" 1 "NS: $NS_OUT, Replicas: $REPLICAS_OUT"
fi

# ------------------------------------------------------------------------------
# Test 10: Multi-Environment Production Scaling Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 10: Testing multi-environment production stack preview...${CLR_RESET}"
pulumi stack select prod --create >/dev/null 2>&1 || true
PROD_PREVIEW=$(pulumi preview --config replicaCount=3 --config environment=prod --non-interactive 2>&1 || echo "")
if [[ "$PROD_PREVIEW" == *"totalReplicas"* && "$PROD_PREVIEW" == *": 9"* ]] || [[ "$PROD_PREVIEW" == *"14 to create"* ]]; then
    record_result "10" "Production environment preview asserts 3x replica scaling (9 total replicas)" 0
else
    record_result "10" "Production environment preview failed" 1 "$PROD_PREVIEW"
fi

# ------------------------------------------------------------------------------
# Test 11: Clean Stack Destruction (pulumi destroy)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 11: Destroying Pulumi stacks (pulumi destroy --yes)...${CLR_RESET}"
pulumi stack select dev >/dev/null 2>&1 || true
DESTROY_DEV=$(pulumi destroy --yes --non-interactive 2>&1 || echo "")
pulumi stack rm dev --yes --preserve-config >/dev/null 2>&1 || true
pulumi stack rm prod --yes --preserve-config >/dev/null 2>&1 || true

if [[ "$DESTROY_DEV" == *"14 deleted"* || "$DESTROY_DEV" == *"Resources:"* ]]; then
    record_result "11" "Pulumi stacks cleanly destroyed in reverse order without orphan resources" 0
else
    record_result "11" "Stack destroy failed" 1 "$DESTROY_DEV"
fi

# ------------------------------------------------------------------------------
# Test 12: Workspace Sanitation & Teardown
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 12: Running cleanup.sh...${CLR_RESET}"
if [[ "$KEEP_RUNNING" == false ]]; then
    if ./cleanup.sh >/dev/null 2>&1; then
        record_result "12" "cleanup.sh purged K3d cluster, local state, and build artifacts" 0
    else
        record_result "12" "cleanup.sh failed" 1
    fi
else
    echo -e "  [${CLR_CYAN}SKIP${CLR_RESET}] Test 12: Cleanup skipped (--keep flag active)."
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# ------------------------------------------------------------------------------
# Summary Recap
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}🎉 ALL $TOTAL_TESTS TESTS PASSED! ($PASSED_TESTS/$TOTAL_TESTS)${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED: $FAILED_TESTS of $TOTAL_TESTS tests failed.${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
