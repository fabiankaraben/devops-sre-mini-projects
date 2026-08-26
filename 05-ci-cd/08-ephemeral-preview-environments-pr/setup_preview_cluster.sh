#!/usr/bin/env bash
# ==============================================================================
# setup_preview_cluster.sh - Automated Provisioner for PR Preview Cluster
# ==============================================================================
# Automates:
#   1. Tool verification (docker, k3d, kubectl, helm)
#   2. Local k3d cluster provisioning with Ingress port mapping (8085:80)
#   3. Isolated kubeconfig management strictly within .tmp_sandbox/
#   4. Building and importing multi-version preview container images
#   5. Ingress controller readiness verification
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"
KUBECONFIG_PATH="${SANDBOX_DIR}/kubeconfig.yaml"
CLUSTER_NAME="preview-env-cluster"
INGRESS_PORT=8085

mkdir -p "$SANDBOX_DIR"

show_help() {
    cat <<EOF
Usage: ./setup_preview_cluster.sh [OPTIONS]

Provisions a local k3d Kubernetes cluster with Ingress routing for PR preview environments.

Options:
  --port <port>   Host port for Ingress routing (default: ${INGRESS_PORT})
  -h, --help      Display this help message

Examples:
  ./setup_preview_cluster.sh              # Start k3d cluster on port 8085
  ./setup_preview_cluster.sh --port 8090  # Start k3d cluster with custom Ingress port
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            INGRESS_PORT="$2"
            shift 2
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 Ephemeral Preview Environments per Pull Request: Setup"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Verify Prerequisites
echo -e "${CLR_YELLOW}▶ [1/4] Verifying CLI prerequisites...${CLR_RESET}"
for bin in docker k3d kubectl helm; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Required tool '${bin}' is not installed or not in PATH." >&2
        exit 1
    fi
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Found: ${bin} ($(command -v "$bin"))"
done

if ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Docker daemon is not running. Please start Docker." >&2
    exit 1
fi
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Docker daemon is running."

# 2. Provision k3d Cluster
echo -e "\n${CLR_YELLOW}▶ [2/4] Provisioning isolated k3d cluster '${CLUSTER_NAME}'...${CLR_RESET}"
if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
    echo -e "  [${CLR_BLUE}INFO${CLR_RESET}] Cluster '${CLUSTER_NAME}' already exists. Reusing existing cluster."
else
    echo "  Creating cluster with Ingress port mapping ${INGRESS_PORT}:80..."
    k3d cluster create "$CLUSTER_NAME" \
        --port "${INGRESS_PORT}:80@loadbalancer" \
        --agents 1 \
        --k3s-arg "--disable=metrics-server@server:0" \
        --wait
fi

# Write isolated kubeconfig
k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Isolated Kubeconfig generated at: ${KUBECONFIG_PATH}"

# 3. Build & Import Sample Container Images
echo -e "\n${CLR_YELLOW}▶ [3/4] Building preview application images and importing into k3d...${CLR_RESET}"
cd "$SCRIPT_DIR"

echo "  Building preview-app:v1.0.0..."
docker build -t preview-app:v1.0.0 ./app --quiet

echo "  Building preview-app:v2.0.0 (updated version for PR sync tests)..."
docker build -t preview-app:v2.0.0 ./app --quiet

echo "  Importing images into k3d cluster..."
k3d image import preview-app:v1.0.0 preview-app:v2.0.0 -c "$CLUSTER_NAME"
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Images successfully loaded into '${CLUSTER_NAME}' container runtime."

# 4. Await Ingress & Cluster Readiness
echo -e "\n${CLR_YELLOW}▶ [4/4] Verifying Ingress controller (Traefik) readiness...${CLR_RESET}"
echo "  Waiting for Traefik Ingress deployment to be initialized..."
for ((i=1; i<=60; i++)); do
    if kubectl get deployment traefik -n kube-system >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
kubectl rollout status deployment/traefik -n kube-system --timeout=120s

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 Preview Environment Cluster Provisioned Successfully!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Cluster Name:      ${CLR_CYAN}${CLUSTER_NAME}${CLR_RESET}"
echo -e "  • Ingress Endpoint:  ${CLR_CYAN}http://localhost:${INGRESS_PORT}${CLR_RESET}"
echo -e "  • Subdomain Pattern: ${CLR_CYAN}pr-<NUMBER>.preview.local${CLR_RESET}"
echo -e "  • Local Kubeconfig:  ${CLR_GRAY}${KUBECONFIG_PATH}${CLR_RESET}"
echo ""
echo -e "  ${CLR_BOLD}Next Steps:${CLR_RESET}"
echo -e "    Run the automated PR lifecycle test suite:"
echo -e "    ${CLR_GREEN}${CLR_BOLD}./test_pr_lifecycle.sh${CLR_RESET}"
echo ""
