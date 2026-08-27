#!/usr/bin/env bash
# ==============================================================================
# setup_cluster.sh - Local K3d Cluster & Chaos Mesh Bootstrapper
# ==============================================================================
# Provisions an isolated local K3d Kubernetes cluster, installs Chaos Mesh
# via Helm with containerd runtime configuration, and deploys the multi-replica
# target application into the 'chaos-lab' namespace.
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
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

CLUSTER_NAME="k3d-chaos-mesh"
KUBECONFIG_PATH="$PROJECT_DIR/.kubeconfig"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 BOOTSTRAPPING K3D CLUSTER & CHAOS MESH OPERATOR"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e " Cluster Name     : ${CLR_BOLD}${CLUSTER_NAME}${CLR_RESET}"
echo -e " Isolated Config  : ${CLR_GRAY}${KUBECONFIG_PATH}${CLR_RESET}"
echo -e " Ingress Port     : ${CLR_BOLD}http://localhost:8088${CLR_RESET}"
echo "======================================================================"

# ------------------------------------------------------------------------------
# STEP 1: Provision K3d Kubernetes Cluster (Strictly Contained)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [1/4] Checking/Creating K3d Cluster...${CLR_RESET}"

CLUSTER_EXISTS=false
if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -q "^${CLUSTER_NAME}$"; then
    CLUSTER_EXISTS=true
fi

if [ "$CLUSTER_EXISTS" = false ]; then
    echo -e "  [${CLR_YELLOW}PROVISION${CLR_RESET}] Creating cluster '$CLUSTER_NAME' (1 server, 1 agent)..."
    k3d cluster create "$CLUSTER_NAME" \
        --servers 1 \
        --agents 1 \
        --port "8088:80@loadbalancer" \
        --port "23790:2379@loadbalancer" \
        --kubeconfig-update-default=false \
        --kubeconfig-switch-context=false \
        --wait >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] K3d cluster '$CLUSTER_NAME' created."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] K3d cluster '$CLUSTER_NAME' already exists."
fi

# Extract isolated kubeconfig
k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kubernetes context connected: $(kubectl config current-context)"

# ------------------------------------------------------------------------------
# STEP 2: Install Chaos Mesh Operator via Helm
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Installing Chaos Mesh Operator (v2.8.4)...${CLR_RESET}"

helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
helm repo update chaos-mesh >/dev/null 2>&1

echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Applying Chaos Mesh Helm chart in namespace 'chaos-mesh'..."
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace chaos-mesh \
    --create-namespace \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock \
    --set dashboard.securityMode=false \
    --wait --timeout=180s >/dev/null

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Chaos Mesh controller and daemons installed."

# ------------------------------------------------------------------------------
# STEP 3: Deploy Target Multi-Replica Application
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Deploying Target Payment API (3 replicas)...${CLR_RESET}"

kubectl apply -f "$PROJECT_DIR/k8s/namespace.yaml" >/dev/null
kubectl apply -f "$PROJECT_DIR/k8s/configmap.yaml" >/dev/null
kubectl apply -f "$PROJECT_DIR/k8s/deployment.yaml" >/dev/null
kubectl apply -f "$PROJECT_DIR/k8s/service.yaml" >/dev/null
kubectl apply -f "$PROJECT_DIR/k8s/pdb.yaml" >/dev/null
kubectl apply -f "$PROJECT_DIR/k8s/ingress.yaml" >/dev/null

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Target application manifests applied to 'chaos-lab'."

# ------------------------------------------------------------------------------
# STEP 4: Wait for All Pods to Reach Ready State
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Awaiting Pod Readiness across namespaces...${CLR_RESET}"

kubectl rollout status deployment/payment-api -n chaos-lab --timeout=120s >/dev/null
kubectl wait --for=condition=Ready pods -l app=payment-api -n chaos-lab --timeout=60s >/dev/null

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All 3 Payment API pods are Running and Ready."

# Test Ingress Connectivity
echo -e "\n${CLR_YELLOW}Testing local ingress endpoint (http://localhost:8088/healthz)...${CLR_RESET}"
MAX_WAIT=20
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "http://localhost:8088/healthz" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${CLR_YELLOW}Warning: Ingress not responding directly; port-forwarding fallback available.${CLR_RESET}"
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Ingress HTTP connectivity verified on port 8088."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Cluster and Target Microservice are fully ready for Chaos Experiments!${CLR_RESET}\n"
