#!/usr/bin/env bash
# ==============================================================================
# cluster_setup.sh - Automated k3d Cluster & Istio Service Mesh Provisioner
# ==============================================================================
# Creates a local k3d Kubernetes cluster, installs the Istio Control Plane (istiod)
# via Helm, and applies workloads with Envoy sidecar injection and Zero-Trust policies.
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

CLUSTER_NAME="istio-mtls-cluster"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 PROVISIONING K3D CLUSTER & ISTIO SERVICE MESH"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Check prerequisites
echo -e "${CLR_YELLOW}▶ [1/5] Checking CLI prerequisites...${CLR_RESET}"
for tool in docker k3d kubectl helm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Required tool '$tool' is not installed or not in PATH."
        exit 1
    fi
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] $tool is available."
done

# 2. Create k3d cluster if not existing
echo -e "\n${CLR_YELLOW}▶ [2/5] Initializing k3d cluster '$CLUSTER_NAME'...${CLR_RESET}"
if k3d cluster list | grep -q "^$CLUSTER_NAME"; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cluster '$CLUSTER_NAME' already exists. Switching kubeconfig..."
    k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context >/dev/null 2>&1
else
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Creating single-node k3d cluster without Traefik..."
    k3d cluster create "$CLUSTER_NAME" \
        --k3s-arg "--disable=traefik@server:0" \
        --wait >/dev/null 2>&1
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cluster '$CLUSTER_NAME' created and ready."
fi

# 3. Install Istio Base & Istiod via Helm
echo -e "\n${CLR_YELLOW}▶ [3/5] Installing Istio Service Mesh Control Plane (istiod)...${CLR_RESET}"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null 2>&1

kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Installing istio-base CRDs..."
helm upgrade --install istio-base istio/base \
    -n istio-system \
    --wait >/dev/null 2>&1

echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] Installing istiod (Control Plane)..."
helm upgrade --install istiod istio/istiod \
    -n istio-system \
    --set pilot.resources.requests.cpu=100m \
    --set pilot.resources.requests.memory=256Mi \
    --set pilot.resources.limits.cpu=500m \
    --set pilot.resources.limits.memory=512Mi \
    --wait >/dev/null 2>&1

kubectl rollout status deployment/istiod -n istio-system --timeout=120s >/dev/null 2>&1
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Istiod control plane is active."

# 4. Apply Kubernetes Manifests & Zero-Trust Policies
echo -e "\n${CLR_YELLOW}▶ [4/5] Deploying Microservices & Zero-Trust Policies...${CLR_RESET}"
kubectl apply -f "$PROJECT_DIR/k8s/00-namespaces.yaml" >/dev/null 2>&1
kubectl apply -f "$PROJECT_DIR/k8s/01-serviceaccounts.yaml" >/dev/null 2>&1
kubectl apply -f "$PROJECT_DIR/k8s/02-backend.yaml" >/dev/null 2>&1
kubectl apply -f "$PROJECT_DIR/k8s/03-frontend.yaml" >/dev/null 2>&1
kubectl apply -f "$PROJECT_DIR/k8s/04-rogue-attacker.yaml" >/dev/null 2>&1
kubectl apply -f "$PROJECT_DIR/k8s/05-peer-authentication.yaml" >/dev/null 2>&1
kubectl apply -f "$PROJECT_DIR/k8s/06-authorization-policy.yaml" >/dev/null 2>&1
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Workloads, PeerAuthentication (STRICT), and AuthorizationPolicy applied."

# 5. Wait for Pod Readiness
echo -e "\n${CLR_YELLOW}▶ [5/5] Waiting for all microservices & Envoy sidecars to become ready...${CLR_RESET}"
kubectl rollout status deployment/backend -n mesh-secure --timeout=120s >/dev/null 2>&1
kubectl rollout status deployment/frontend -n mesh-secure --timeout=120s >/dev/null 2>&1
kubectl rollout status deployment/rogue-attacker -n mesh-unmanaged --timeout=120s >/dev/null 2>&1

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Frontend (2/2), Backend (2/2), and Rogue Attacker (1/1) are running."

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================"
echo "  ✅ ISTIO SERVICE MESH & ZERO-TRUST WORKLOADS READY"
echo "======================================================================${CLR_RESET}\n"
