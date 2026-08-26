#!/usr/bin/env bash
# ==============================================================================
# setup_gitops_cluster.sh - GitOps ArgoCD Cluster & Environment Provisioner
# ==============================================================================
# Automates:
#   1. Local k3d cluster creation (with ingress/loadbalancer port mappings)
#   2. ArgoCD Control Plane deployment & readiness health checks
#   3. In-cluster Git server initialization with seed application manifests
#   4. ArgoCD Application CRD registration (gitops-webapp)
#   5. Admin credential retrieval and connection helper instructions
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
CLUSTER_NAME="gitops-argocd-cluster"
ARGOCD_VERSION="v2.13.0"
ARGOCD_MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
ARGOCD_NS="argocd"
GIT_NS="gitops-system"
APP_NS="gitops-demo"
SKIP_CLUSTER_CREATE=false
TIMEOUT_SEC=180

show_help() {
    cat <<EOF
Usage: ./setup_gitops_cluster.sh [OPTIONS]

Provisions a local k3d Kubernetes cluster with ArgoCD and in-cluster Git repository.

Options:
  --cluster-name <name>   Name of k3d cluster (default: ${CLUSTER_NAME})
  --skip-cluster          Skip cluster creation (use currently active kubecontext)
  --timeout <seconds>     Readiness timeout for pods in seconds (default: ${TIMEOUT_SEC})
  -h, --help              Display this help message

Examples:
  ./setup_gitops_cluster.sh               # Full local setup with k3d and ArgoCD
  ./setup_gitops_cluster.sh --skip-cluster # Deploy ArgoCD into existing cluster
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --skip-cluster)
            SKIP_CLUSTER_CREATE=true
            shift
            ;;
        --timeout)
            TIMEOUT_SEC="$2"
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
echo "  🚀 GitOps Continuous Delivery with ArgoCD: Environment Setup"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Dependency Checks
echo -e "${CLR_YELLOW}▶ [1/5] Verifying CLI prerequisites...${CLR_RESET}"
for bin in docker kubectl; do
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

if [[ "$SKIP_CLUSTER_CREATE" == false ]]; then
    if ! command -v k3d >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] 'k3d' is required for automated cluster creation." >&2
        echo "  Install via Homebrew: brew install k3d, or run with --skip-cluster on existing Kubernetes." >&2
        exit 1
    fi
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Found: k3d ($(command -v k3d))"
fi

# 2. Cluster Provisioning
echo -e "\n${CLR_YELLOW}▶ [2/5] Initializing Kubernetes Cluster...${CLR_RESET}"
if [[ "$SKIP_CLUSTER_CREATE" == true ]]; then
    CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "unknown")
    echo -e "  [${CLR_BLUE}INFO${CLR_RESET}] Skipping k3d creation. Using current context: ${CLR_BOLD}${CURRENT_CTX}${CLR_RESET}"
else
    if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
        echo -e "  [${CLR_BLUE}INFO${CLR_RESET}] k3d cluster '${CLUSTER_NAME}' already exists. Using existing cluster."
    else
        echo "  Creating k3d cluster '${CLUSTER_NAME}'..."
        k3d cluster create "$CLUSTER_NAME" \
            --servers 1 \
            --agents 0 \
            --port "8080:80@loadbalancer" \
            --port "8081:8081@loadbalancer" \
            --wait
        echo -e "  [${CLR_GREEN}✓${CLR_RESET}] k3d cluster '${CLUSTER_NAME}' created successfully."
    fi
    kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
fi

# 3. Deploy in-cluster Git Server
echo -e "\n${CLR_YELLOW}▶ [3/5] Deploying in-cluster Git Repository Server...${CLR_RESET}"
kubectl apply -f "${SCRIPT_DIR}/git-server/git-server.yaml"

echo "  Waiting for Git Server pod readiness..."
kubectl rollout status deployment/git-server -n "$GIT_NS" --timeout="${TIMEOUT_SEC}s"
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Git Repository Server is ready and seeded with manifests."

# 4. Install ArgoCD
echo -e "\n${CLR_YELLOW}▶ [4/5] Deploying ArgoCD Control Plane (${ARGOCD_VERSION})...${CLR_RESET}"
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -

# Cache manifest locally inside mini-project sandbox to support quick offline re-runs
CACHE_DIR="${SCRIPT_DIR}/.tmp_sandbox"
mkdir -p "$CACHE_DIR"
CACHED_MANIFEST="${CACHE_DIR}/argocd-install.yaml"

if [[ ! -f "$CACHED_MANIFEST" ]]; then
    echo "  Downloading ArgoCD manifests (${ARGOCD_VERSION})..."
    if curl -sSL -f -m 30 "$ARGOCD_MANIFEST_URL" -o "$CACHED_MANIFEST"; then
        echo -e "  [${CLR_GREEN}✓${CLR_RESET}] ArgoCD manifests cached at ${CACHED_MANIFEST}"
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Failed to fetch remote manifest, falling back to direct apply..."
        CACHED_MANIFEST="$ARGOCD_MANIFEST_URL"
    fi
fi

kubectl apply -n "$ARGOCD_NS" -f "$CACHED_MANIFEST"

echo "  Waiting for ArgoCD components (repo-server, controller, server)..."
kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NS" --timeout="${TIMEOUT_SEC}s"
kubectl rollout status deployment/argocd-server -n "$ARGOCD_NS" --timeout="${TIMEOUT_SEC}s"
kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NS" --timeout="${TIMEOUT_SEC}s" 2>/dev/null || \
kubectl rollout status deployment/argocd-application-controller -n "$ARGOCD_NS" --timeout="${TIMEOUT_SEC}s"

echo -e "  [${CLR_GREEN}✓${CLR_RESET}] ArgoCD Control Plane is fully operational."

# 5. Register ArgoCD Application CRD
echo -e "\n${CLR_YELLOW}▶ [5/5] Registering GitOps Application (${CLR_BOLD}gitops-webapp${CLR_RESET}${CLR_YELLOW})...${CLR_RESET}"
kubectl apply -f "${SCRIPT_DIR}/argocd_app.yaml"
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] ArgoCD Application 'gitops-webapp' created."

# Fetch initial admin password
ADMIN_PASS=""
for _ in {1..30}; do
    if kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
        ADMIN_PASS=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode || true)
        break
    fi
    sleep 1
done

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 GitOps Environment Provisioning Complete!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  ${CLR_BOLD}ArgoCD Web UI Access:${CLR_RESET}"
echo -e "    • URL:      ${CLR_CYAN}https://localhost:8080${CLR_RESET} (or port-forward port 8080)"
echo -e "    • Username: ${CLR_CYAN}admin${CLR_RESET}"
if [[ -n "$ADMIN_PASS" ]]; then
    echo -e "    • Password: ${CLR_CYAN}${ADMIN_PASS}${CLR_RESET}"
else
    echo -e "    • Password: (Retrieve with: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
fi
echo ""
echo -e "  ${CLR_BOLD}Quick Port-Forward Commands:${CLR_RESET}"
echo -e "    • ArgoCD UI:  ${CLR_GRAY}kubectl port-forward -n argocd svc/argocd-server 8080:443${CLR_RESET}"
echo -e "    • Git Server: ${CLR_GRAY}kubectl port-forward -n gitops-system svc/git-server 9418:9418${CLR_RESET}"
echo -e "    • Target App: ${CLR_GRAY}kubectl port-forward -n gitops-demo svc/gitops-webapp 8082:80${CLR_RESET}"
echo ""
echo -e "  ${CLR_BOLD}Next Steps:${CLR_RESET}"
echo -e "    Run the automated GitOps sync test suite:"
echo -e "    ${CLR_GREEN}${CLR_BOLD}./gitops_sync_test.sh${CLR_RESET}"
echo ""
