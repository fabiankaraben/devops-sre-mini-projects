#!/usr/bin/env bash
# ==============================================================================
# test_pipeline.sh - Automated End-to-End Test Runner for Fluent Bit DaemonSet
# ==============================================================================
# 1. Checks prerequisites (Docker, Kubectl, Python 3, K3d).
# 2. Ensures a Kubernetes cluster is available (provisions K3d cluster if needed).
# 3. Deploys Namespaces, RBAC, ConfigMap, DaemonSet, and multi-namespace workloads.
# 4. Awaits Pod readiness across all namespaces.
# 5. Executes the metadata enrichment audit.
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

CLUSTER_NAME="fluent-bit-lab"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 Fluent Bit Kubernetes Log DaemonSet - Automated Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Check Prerequisites & Kubernetes Cluster
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites & Cluster Reachability...${CLR_RESET}"

if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] kubectl is required but not installed."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] kubectl is available."

CLUSTER_ONLINE=false
if kubectl cluster-info >/dev/null 2>&1; then
    CLUSTER_ONLINE=true
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Connected to active Kubernetes cluster."
else
    if command -v k3d >/dev/null 2>&1; then
        echo "  No active cluster detected. Creating local K3d cluster '${CLUSTER_NAME}'..."
        k3d cluster create "$CLUSTER_NAME" --servers 1 --agents 1 --wait
        CLUSTER_ONLINE=true
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] K3d cluster '${CLUSTER_NAME}' created successfully."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] No Kubernetes cluster reachable and K3d is not installed."
        echo "  Please start Minikube, K3d, OrbStack Kubernetes, or Docker Desktop Kubernetes."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 2. Deploy Logging Infrastructure (Namespaces, RBAC, ConfigMap, DaemonSet)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Deploying Fluent Bit Logging DaemonSet & RBAC...${CLR_RESET}"

kubectl apply -f "$SCRIPT_DIR/k8s/00-namespace.yaml" >/dev/null
kubectl apply -f "$SCRIPT_DIR/k8s/01-rbac.yaml" >/dev/null
kubectl apply -f "$SCRIPT_DIR/k8s/02-fluent-bit-config.yaml" >/dev/null
kubectl apply -f "$SCRIPT_DIR/k8s/03-fluent-bit-daemonset.yaml" >/dev/null

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Fluent Bit manifests applied to cluster."

# ------------------------------------------------------------------------------
# 3. Deploy Multi-Namespace Sample Workloads
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Deploying Multi-Namespace Workloads (frontend-ns, backend-ns, analytics-ns)...${CLR_RESET}"

kubectl apply -f "$SCRIPT_DIR/k8s/04-workloads/" >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Workload Deployments applied."

# ------------------------------------------------------------------------------
# 4. Await Readiness Across All Namespaces
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Waiting for Pod Readiness Across All Namespaces...${CLR_RESET}"

echo "  Waiting for Fluent Bit DaemonSet..."
kubectl rollout status daemonset/fluent-bit -n logging --timeout=120s >/dev/null

echo "  Waiting for frontend-app deployment..."
kubectl rollout status deployment/frontend-app -n frontend-ns --timeout=120s >/dev/null

echo "  Waiting for payment-service deployment..."
kubectl rollout status deployment/payment-service -n backend-ns --timeout=120s >/dev/null

echo "  Waiting for analytics-worker deployment..."
kubectl rollout status deployment/analytics-worker -n analytics-ns --timeout=120s >/dev/null

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All workloads and Fluent Bit DaemonSets are running."

echo "  Allowing 10 seconds for workloads to generate logs and Fluent Bit to scrape and enrich..."
sleep 10

# ------------------------------------------------------------------------------
# 5. Run Kubernetes Log Metadata Audit
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Executing Kubernetes Log Metadata Audit...${CLR_RESET}"

"$SCRIPT_DIR/k8s_log_metadata_audit.sh"

echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 ALL TESTS PASSED: FLUENT BIT METADATA ENRICHMENT VERIFIED!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "\n${CLR_CYAN}Next Steps:${CLR_RESET}"
echo -e "  • Inspect live Fluent Bit logs:   ${CLR_BOLD}kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit -f${CLR_RESET}"
echo -e "  • Query collector metrics:        ${CLR_BOLD}kubectl port-forward -n logging ds/fluent-bit 2020:2020 & curl http://localhost:2020/api/v1/metrics${CLR_RESET}"
echo -e "  • Teardown environment:           ${CLR_BOLD}./cleanup.sh --all${CLR_RESET}\n"
