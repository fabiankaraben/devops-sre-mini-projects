#!/usr/bin/env bash
# ==============================================================================
# deploy_admission_controller.sh - Automated Kyverno Admission Controller Setup
# ==============================================================================
# Verifies or spins up a local K3d Kubernetes cluster, deploys Kyverno admission
# controller via Helm/manifests, waits for webhook readiness, and applies
# cluster-wide security governance policies.
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

CLUSTER_NAME="admission-sandbox"
NAMESPACE="admission-security-demo"
POLICIES_DIR="$SCRIPT_DIR/policies/kyverno"

print_usage() {
    echo -e "${CLR_CYAN}Usage: ./deploy_admission_controller.sh [OPTIONS]${CLR_RESET}"
    echo ""
    echo "Options:"
    echo "  --cluster-name <NAME>   Name of the K3d cluster (default: admission-sandbox)"
    echo "  --namespace <NAME>      Test namespace (default: admission-security-demo)"
    echo "  --help, -h              Show this help message"
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Error: Unknown argument '$1'${CLR_RESET}"
            print_usage
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🛡️  KUBERNETES ADMISSION CONTROLLER & POLICY BOOTSTRAPPER"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e " Cluster Target   : ${CLR_BOLD}${CLUSTER_NAME}${CLR_RESET}"
echo -e " Test Namespace   : ${CLR_BOLD}${NAMESPACE}${CLR_RESET}"
echo -e " Policies Source  : ${CLR_GRAY}${POLICIES_DIR}${CLR_RESET}"
echo "======================================================================"

# ------------------------------------------------------------------------------
# STEP 1: Verify / Provision K3d Kubernetes Cluster
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [1/4] Checking Kubernetes Cluster Connectivity...${CLR_RESET}"

CLUSTER_EXISTS=false
if command -v k3d >/dev/null 2>&1; then
    if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -q "^${CLUSTER_NAME}$"; then
        CLUSTER_EXISTS=true
    fi
fi

if [ "$CLUSTER_EXISTS" = false ] && ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "  [${CLR_MAGENTA}PROVISION${CLR_RESET}] Cluster '$CLUSTER_NAME' not found. Creating local K3d cluster..."
    if command -v k3d >/dev/null 2>&1; then
        k3d cluster create "$CLUSTER_NAME" --wait >/dev/null 2>&1
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] K3d cluster '$CLUSTER_NAME' created and active."
    else
        echo -e "${CLR_RED}Error: Neither an active Kubernetes cluster nor 'k3d' CLI was found.${CLR_RESET}"
        exit 1
    fi
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kubernetes cluster is reachable ($(kubectl config current-context))."
fi

# ------------------------------------------------------------------------------
# STEP 2: Deploy Kyverno Admission Controller
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Deploying Kyverno Admission Controller...${CLR_RESET}"

if ! kubectl get namespace kyverno >/dev/null 2>&1 || ! kubectl get deployment -n kyverno kyverno-admission-controller >/dev/null 2>&1; then
    echo -e "  [${CLR_GRAY}HELM${CLR_RESET}] Installing Kyverno Helm chart..."
    if command -v helm >/dev/null 2>&1; then
        helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
        helm repo update >/dev/null 2>&1 || true
        helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace >/dev/null 2>&1
    else
        echo -e "  [${CLR_GRAY}KUBECTL${CLR_RESET}] Helm not found, applying Kyverno official release YAML..."
        kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.12.5/install.yaml >/dev/null 2>&1
    fi
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kyverno deployment already present in namespace 'kyverno'."
fi

# ------------------------------------------------------------------------------
# STEP 3: Wait for Admission Webhook Readiness
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Waiting for Kyverno Admission Controller Webhook Readiness...${CLR_RESET}"
echo -e "  [${CLR_GRAY}WAIT${CLR_RESET}] Waiting for admission webhook pod to report Ready..."

if kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=admission-controller -n kyverno --timeout=120s >/dev/null 2>&1; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kyverno Admission Webhook is fully operational."
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Timeout waiting for admission-controller pod. Checking status..."
    kubectl get pods -n kyverno
fi

# ------------------------------------------------------------------------------
# STEP 4: Apply ClusterPolicies & Create Test Namespace
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Creating Test Namespace and Registering ClusterPolicies...${CLR_RESET}"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Test namespace '$NAMESPACE' configured."

echo -e "  [${CLR_GRAY}POLICIES${CLR_RESET}] Applying Kyverno ClusterPolicy definitions..."
kubectl apply -f "$POLICIES_DIR" >/dev/null 2>&1

POLICY_COUNT=$(kubectl get clusterpolicies --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Successfully enrolled ${CLR_BOLD}${POLICY_COUNT}${CLR_RESET} ClusterPolicies in admission webhooks."

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================"
echo "  ✅ ADMISSION CONTROLLER & POLICIES SUCCESSFULLY DEPLOYED"
echo "======================================================================${CLR_RESET}"
echo -e " Run Policy Audit : ${CLR_CYAN}./admission_policy_audit.sh${CLR_RESET}"
echo "======================================================================"
