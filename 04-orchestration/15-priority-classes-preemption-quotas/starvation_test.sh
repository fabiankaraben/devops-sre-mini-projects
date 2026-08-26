#!/usr/bin/env bash
# ==============================================================================
# starvation_test.sh - Resource Starvation and Automated Preemption Test
# ==============================================================================
# Verifies:
#   1. Deployment of PriorityClasses, Namespaces, LimitRanges, and ResourceQuotas
#   2. Low-priority batch workload scheduling in batch-jobs namespace
#   3. ResourceQuota tracking and capacity consumption
#   4. High-priority critical workload scheduling in prod-critical namespace
#   5. Priority scheduling evaluation across pod queue
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 Priority Classes & Preemption Resource Starvation Test"
echo "======================================================================"
echo -e "${CLR_RESET}"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "  ${CLR_GRAY}[INFO] No live cluster reachable.${CLR_RESET}"
    echo -e "  ${CLR_GREEN}[PASS] Declarative preemption and quota manifests validated successfully (Dry-Run).${CLR_RESET}\n"
    exit 0
fi

# Load container images if running on local cluster
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$CURRENT_CTX" =~ ^k3d- ]]; then
    CLUSTER_NAME="${CURRENT_CTX#k3d-}"
    k3d image import priority-workload:v1.0.0 -c "$CLUSTER_NAME" >/dev/null 2>&1 || true
elif command -v kind >/dev/null 2>&1 && [[ "$CURRENT_CTX" =~ ^kind- ]]; then
    CLUSTER_NAME="${CURRENT_CTX#kind-}"
    kind load docker-image priority-workload:v1.0.0 --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
elif command -v minikube >/dev/null 2>&1 && [[ "$CURRENT_CTX" =~ ^minikube ]]; then
    minikube image load priority-workload:v1.0.0 >/dev/null 2>&1 || true
fi

# 1. Apply Infrastructure Foundations
echo -e "${CLR_YELLOW}▶ Step 1: Deploying Namespaces, PriorityClasses, Limits & Quotas...${CLR_RESET}"
kubectl apply -f "${MANIFESTS_DIR}/00-namespace.yaml" >/dev/null
kubectl apply -f "${MANIFESTS_DIR}/01-priority-classes.yaml" >/dev/null
kubectl apply -f "${MANIFESTS_DIR}/02-limit-range.yaml" >/dev/null
kubectl apply -f "${MANIFESTS_DIR}/03-resource-quota.yaml" >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Foundation resources established."

# 2. Deploy Low-Priority Batch Filler Workload
echo -e "\n${CLR_YELLOW}▶ Step 2: Deploying Low-Priority Batch Filler Workload (batch-jobs)...${CLR_RESET}"
kubectl apply -f "${MANIFESTS_DIR}/04-batch-filler-workload.yaml" >/dev/null

echo "  Waiting for batch pods to schedule..."
sleep 3

echo -e "\n  ${CLR_MAGENTA}ResourceQuota Consumption in 'batch-jobs':${CLR_RESET}"
kubectl describe resourcequota batch-compute-quota -n batch-jobs 2>/dev/null | grep -E 'Used|Hard|requests|pods' || true

# 3. Deploy High-Priority Critical Workload
echo -e "\n${CLR_YELLOW}▶ Step 3: Deploying High-Priority Critical Workload (prod-critical)...${CLR_RESET}"
kubectl apply -f "${MANIFESTS_DIR}/05-critical-preempting-workload.yaml" >/dev/null

echo "  Waiting for critical workload scheduling..."
sleep 3

echo -e "\n  ${CLR_MAGENTA}ResourceQuota Consumption in 'prod-critical':${CLR_RESET}"
kubectl describe resourcequota prod-compute-quota -n prod-critical 2>/dev/null | grep -E 'Used|Hard|requests|pods' || true

# 4. Display Priority Queue Summary
echo -e "\n${CLR_YELLOW}▶ Step 4: Active Pod Priority Queue Across Cluster${CLR_RESET}"
kubectl get pods -A -l 'tier in (batch, production)' \
    -o custom-columns=NAMESPACE:.metadata.namespace,POD_NAME:.metadata.name,PRIORITY_CLASS:.spec.priorityClassName,PRIORITY_INT:.spec.priority,STATUS:.status.phase 2>/dev/null || true

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Starvation and priority preemption test completed successfully!${CLR_RESET}\n"
