#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Runner for kube-prometheus-stack (08-09)
# ==============================================================================
# 1. Validates local tools (Docker, k3d, kubectl, Helm, Python 3).
# 2. Spins up an isolated local k3d cluster with NodePort port-mappings.
# 3. Deploys kube-prometheus-stack via Helm with custom values.yaml.
# 4. Builds and loads the sample microservice image into the k3d cluster.
# 5. Applies declarative CRDs (ServiceMonitor, PodMonitor, PrometheusRule).
# 6. Runs k8s_monitoring_test.sh to validate dynamic discovery and alerting.
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

CLUSTER_NAME="k3d-kube-prom-stack"
KUBECTL_CTX="k3d-${CLUSTER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ☸️ kube-prometheus-stack Observability - Master Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Tool Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/6] Checking Tool Prerequisites...${CLR_RESET}"

for tool in docker k3d kubectl helm curl python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Required tool '$tool' is not installed."
        exit 1
    fi
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Tool '$tool' is available."
done

# ------------------------------------------------------------------------------
# 2. Local Kubernetes Cluster Creation (k3d)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/6] Provisioning Local k3d Kubernetes Cluster...${CLR_RESET}"

if k3d cluster list | grep -q "$CLUSTER_NAME"; then
    echo "  Cluster '$CLUSTER_NAME' already exists. Using existing cluster."
else
    echo "  Creating k3d cluster '$CLUSTER_NAME' with NodePort bindings (:30090, :30030, :30093, :30080)..."
    k3d cluster create "$CLUSTER_NAME" \
      --servers 1 \
      --agents 1 \
      --port "30090:30090@server:0" \
      --port "30030:30030@server:0" \
      --port "30093:30093@server:0" \
      --port "30080:30080@server:0" \
      --wait
fi

kubectl config use-context "$KUBECTL_CTX" >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Kubernetes context set to '${KUBECTL_CTX}'"

# ------------------------------------------------------------------------------
# 3. Helm Repository Setup
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/6] Configuring Helm Repositories...${CLR_RESET}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] 'prometheus-community' Helm repository updated."

# ------------------------------------------------------------------------------
# 4. Deploy kube-prometheus-stack via Helm
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/6] Deploying kube-prometheus-stack Helm Release...${CLR_RESET}"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values ./helm/values.yaml \
  --wait \
  --timeout 10m

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] kube-prometheus-stack Helm chart deployed successfully."

# ------------------------------------------------------------------------------
# 5. Build and Import Sample App & Apply Declarative CRDs
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/6] Building & Deploying Monitored Application and CRDs...${CLR_RESET}"

echo "  Building 'order-api:local' Docker image..."
docker build -t order-api:local ./app >/dev/null

echo "  Importing 'order-api:local' image into k3d cluster..."
k3d image import order-api:local -c "$CLUSTER_NAME"

echo "  Applying Kubernetes manifests (Deployment, Service, ServiceMonitor, PodMonitor, PrometheusRule)..."
kubectl apply -f ./manifests/

echo "  Awaiting Deployment rollout (order-api)..."
kubectl rollout status deployment/order-api -n default --timeout=60s
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Application and monitoring CRDs active in cluster."
echo "  Allowing Prometheus Operator reconciliation cycle (4s)..."
sleep 4

# ------------------------------------------------------------------------------
# 6. Execute End-to-End Test Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [6/6] Executing Kubernetes Monitoring Test Suite...${CLR_RESET}"
./k8s_monitoring_test.sh

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All Kubernetes Observability Tests Passed!${CLR_RESET}"
echo -e "🔗 Prometheus Web UI:  ${CLR_CYAN}http://localhost:30090${CLR_RESET}"
echo -e "🔗 Grafana Dashboard:  ${CLR_CYAN}http://localhost:30030${CLR_RESET} (Login: ${CLR_BOLD}admin${CLR_RESET} / ${CLR_BOLD}prom-operator${CLR_RESET})"
echo -e "🔗 Alertmanager UI:    ${CLR_CYAN}http://localhost:30093${CLR_RESET}"
echo -e "🔗 Order API Service:  ${CLR_CYAN}http://localhost:30080/docs${CLR_RESET}"
echo -e "\nTo clean up all cluster resources and images, execute:"
echo -e "  ${CLR_BOLD}./cleanup.sh --purge-images${CLR_RESET}\n"
