#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 08-09
# ==============================================================================
# Deletes Kubernetes manifests, uninstalls the kube-prometheus-stack Helm chart,
# tears down the local k3d cluster, and optionally purges built Docker images.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_IMAGES=false

for arg in "$@"; do
    case "$arg" in
        --all|--purge-images)
            PURGE_IMAGES=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-images   Purge local container images after cluster teardown"
            echo "  --help, -h              Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./cleanup.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up kube-prometheus-stack Kubernetes Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Delete Kubernetes Resources & Helm Release (If cluster reachable)
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Deleting Kubernetes Manifests and Helm Releases...${CLR_RESET}"

if command -v k3d >/dev/null 2>&1 && k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    kubectl delete -f ./manifests/ --ignore-not-found=true --context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Custom CRD manifests and sample app deleted."

    helm uninstall kube-prometheus-stack -n monitoring --kube-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] kube-prometheus-stack Helm release uninstalled."

    # Delete k3d cluster completely
    echo "  Deleting k3d cluster '$CLUSTER_NAME'..."
    k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] k3d cluster '$CLUSTER_NAME' deleted."
else
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cluster '$CLUSTER_NAME' is not active."
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging project Docker images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f order-api:local >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Container image 'order-api:local' removed."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete them).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Temporary Files & Cache
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary Python artifacts and caches...${CLR_RESET}"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
rm -rf "$SCRIPT_DIR/.tmp_e2e" 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files and cache directories cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean and ready for subsequent mini-projects!${CLR_RESET}\n"
