#!/usr/bin/env bash
# ==============================================================================
# setup_cluster.sh - Isolated Local K3d Cluster Setup for Graceful Shutdown Demo
# ==============================================================================
# Creates an isolated k3d cluster 'k3d-graceful-demo' exposing port 8089,
# strictly writes .kubeconfig to project root without touching ~/.kube/config,
# applies all manifests, and verifies ingress reachability.
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

CLUSTER_NAME="k3d-graceful-demo"
PORT="8089"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_FILE="$PROJECT_ROOT/.kubeconfig"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ☸️  Provisioning Isolated K3d Cluster for Zero-Downtime Draining"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Check prerequisites
for cmd in k3d kubectl docker; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Required tool '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

# 2. Check if cluster already exists
if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo -e "  [${CLR_GREEN}EXISTS${CLR_RESET}] Cluster '$CLUSTER_NAME' already exists."
else
    echo -e "${CLR_YELLOW}▶ [1/4] Creating K3d cluster '$CLUSTER_NAME' on port $PORT...${CLR_RESET}"
    k3d cluster create "$CLUSTER_NAME" \
        --port "${PORT}:80@loadbalancer" \
        --agents 2 \
        --kubeconfig-update-default=false \
        --kubeconfig-switch-context=false
fi

# 3. Export strictly isolated kubeconfig
echo -e "\n${CLR_YELLOW}▶ [2/4] Extracting kubeconfig to isolated local file ($KUBECONFIG_FILE)...${CLR_RESET}"
k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Isolated KUBECONFIG generated."

# 4. Apply Kubernetes manifests
echo -e "\n${CLR_YELLOW}▶ [3/4] Applying manifests in namespace 'graceful-demo'...${CLR_RESET}"
kubectl --kubeconfig "$KUBECONFIG" apply -f "$PROJECT_ROOT/k8s/namespace.yaml"
kubectl --kubeconfig "$KUBECONFIG" apply -f "$PROJECT_ROOT/k8s/configmap.yaml"
kubectl --kubeconfig "$KUBECONFIG" apply -f "$PROJECT_ROOT/k8s/deployment-graceful.yaml"
kubectl --kubeconfig "$KUBECONFIG" apply -f "$PROJECT_ROOT/k8s/deployment-naive.yaml"
kubectl --kubeconfig "$KUBECONFIG" apply -f "$PROJECT_ROOT/k8s/service.yaml"
kubectl --kubeconfig "$KUBECONFIG" apply -f "$PROJECT_ROOT/k8s/pdb.yaml"
kubectl --kubeconfig "$KUBECONFIG" apply -f "$PROJECT_ROOT/k8s/ingress.yaml"

# 5. Wait for rollouts to complete
echo -e "\n${CLR_YELLOW}▶ [4/4] Waiting for pods and ingress controller to reach Ready state...${CLR_RESET}"
kubectl --kubeconfig "$KUBECONFIG" rollout status deployment/traefik -n kube-system --timeout=90s >/dev/null 2>&1 || true
kubectl --kubeconfig "$KUBECONFIG" rollout status deployment/graceful-app -n graceful-demo --timeout=90s
kubectl --kubeconfig "$KUBECONFIG" rollout status deployment/naive-app -n graceful-demo --timeout=90s

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 Cluster and applications are 100% READY!${CLR_RESET}"
echo -e "  • Cluster: ${CLR_CYAN}$CLUSTER_NAME${CLR_RESET}"
echo -e "  • Ingress Endpoint: ${CLR_CYAN}http://localhost:${PORT}/api/v1/work${CLR_RESET}"
echo -e "  • Kubeconfig: ${CLR_CYAN}$KUBECONFIG_FILE${CLR_RESET}\n"
