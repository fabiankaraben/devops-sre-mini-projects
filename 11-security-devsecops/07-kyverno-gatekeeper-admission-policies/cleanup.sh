#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 11-07
# ==============================================================================
# Cleans up test namespaces, pods, Kyverno admission policies, Helm releases,
# generated audit reports, and optionally deletes the local K3d cluster.
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

CLUSTER_NAME="admission-sandbox"
NAMESPACE="admission-security-demo"
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
            echo "  --all, --delete-cluster   Delete the local K3d cluster '$CLUSTER_NAME' as well"
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
echo "  🧹 Cleaning Up Kubernetes Admission Control Sandbox Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Clean Test Workloads & Namespace
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Removing test workloads and demo namespace...${CLR_RESET}"
if kubectl cluster-info >/dev/null 2>&1; then
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespace '$NAMESPACE' and associated pods removed."
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] Kubernetes cluster not reachable; skipping namespace cleanup."
fi

# ------------------------------------------------------------------------------
# 2. Remove Kyverno ClusterPolicies & Controller Installation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/3] Removing Kyverno ClusterPolicies & Helm deployment...${CLR_RESET}"
if kubectl cluster-info >/dev/null 2>&1; then
    kubectl delete clusterpolicies --all --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kyverno ClusterPolicies removed."
    
    if command -v helm >/dev/null 2>&1 && helm status kyverno -n kyverno >/dev/null 2>&1; then
        helm uninstall kyverno -n kyverno >/dev/null 2>&1 || true
        kubectl delete namespace kyverno --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kyverno Helm release and namespace removed."
    fi
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] Kubernetes cluster not reachable; skipping Kyverno removal."
fi

# ------------------------------------------------------------------------------
# 3. Optionally Delete Local K3d Cluster & Clean Local Reports
# ------------------------------------------------------------------------------
if [ "$DELETE_CLUSTER" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [3/3] Deleting K3d cluster '$CLUSTER_NAME' & local reports...${CLR_RESET}"
    if command -v k3d >/dev/null 2>&1; then
        if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -q "^${CLUSTER_NAME}$"; then
            k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] K3d cluster '$CLUSTER_NAME' deleted."
        fi
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [3/3] Preserving K3d cluster (use --all or --delete-cluster to destroy it)...${CLR_RESET}"
fi

rm -rf "$SCRIPT_DIR/reports"
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Generated audit reports and logs removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is clean! Ready for subsequent projects.${CLR_RESET}\n"
