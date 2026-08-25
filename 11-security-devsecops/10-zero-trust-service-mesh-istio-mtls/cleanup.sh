#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 11-10
# ==============================================================================
# Cleans up workloads, Istio Zero-Trust policies, namespaces, and optionally
# deletes the local k3d cluster and purging all resources.
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
cd "$SCRIPT_DIR"

DELETE_CLUSTER=false

for arg in "$@"; do
    case "$arg" in
        --all|--delete-cluster)
            DELETE_CLUSTER=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --delete-cluster   Delete the entire k3d cluster ($CLUSTER_NAME)"
            echo "  --help, -h                Show this help message"
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
echo "  🧹 Cleaning Up Istio Zero-Trust Service Mesh Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Delete k3d cluster if requested
if [ "$DELETE_CLUSTER" = true ]; then
    echo -e "${CLR_YELLOW}▶ [1/2] Deleting k3d cluster '$CLUSTER_NAME'...${CLR_RESET}"
    if command -v k3d >/dev/null 2>&1 && k3d cluster list | grep -q "^$CLUSTER_NAME"; then
        k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] k3d cluster '$CLUSTER_NAME' deleted."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Cluster '$CLUSTER_NAME' not found."
    fi
else
    # Delete application namespaces and Istio releases
    echo -e "${CLR_YELLOW}▶ [1/2] Removing application namespaces & Istio resources...${CLR_RESET}"
    if command -v kubectl >/dev/null 2>&1; then
        kubectl delete namespace mesh-secure mesh-unmanaged --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
        if command -v helm >/dev/null 2>&1; then
            helm uninstall istiod -n istio-system >/dev/null 2>&1 || true
            helm uninstall istio-base -n istio-system >/dev/null 2>&1 || true
        fi
        kubectl delete namespace istio-system --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespaces and Istio releases removed (use --all to delete the k3d cluster)."
    fi
fi

# 2. Clean local reports and logs
echo -e "\n${CLR_YELLOW}▶ [2/2] Cleaning local report artifacts...${CLR_RESET}"
rm -rf "$SCRIPT_DIR/reports"
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local reports and temporary logs removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is clean! Ready for subsequent projects.${CLR_RESET}\n"
