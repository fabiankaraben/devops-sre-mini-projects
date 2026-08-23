#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 09-05
# ==============================================================================
# Deletes Kubernetes namespaces, workloads, DaemonSet, RBAC objects, and optionally
# tears down the local K3d cluster.
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

CLUSTER_NAME="fluent-bit-lab"
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
            echo "  --all, --delete-cluster   Tear down the local K3d cluster ('${CLUSTER_NAME}')"
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
echo "  🧹 Cleaning Up Fluent Bit Kubernetes DaemonSet Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Delete Kubernetes Namespaces & RBAC Objects
# ------------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${CLR_YELLOW}▶ [1/3] Deleting Workloads, Namespaces, and RBAC...${CLR_RESET}"

    kubectl delete -f "$SCRIPT_DIR/k8s/04-workloads/" --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete -f "$SCRIPT_DIR/k8s/03-fluent-bit-daemonset.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete -f "$SCRIPT_DIR/k8s/02-fluent-bit-config.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete -f "$SCRIPT_DIR/k8s/01-rbac.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete -f "$SCRIPT_DIR/k8s/00-namespace.yaml" --ignore-not-found=true >/dev/null 2>&1 || true

    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespaces 'logging', 'frontend-ns', 'backend-ns', 'analytics-ns' deleted."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] ClusterRole and ClusterRoleBinding removed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active cluster connected, skipping namespace deletion."
fi

# ------------------------------------------------------------------------------
# 2. Optionally Delete Local K3d Cluster
# ------------------------------------------------------------------------------
if [ "$DELETE_CLUSTER" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Deleting K3d cluster '${CLUSTER_NAME}'...${CLR_RESET}"
    if command -v k3d >/dev/null 2>&1; then
        if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
            k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] K3d cluster '${CLUSTER_NAME}' deleted."
        else
            echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] K3d cluster '${CLUSTER_NAME}' not found."
        fi
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Keeping K3d cluster intact (use --all to delete cluster).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Local Cache Files
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local temporary Python cache and log files...${CLR_RESET}"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ TEARDOWN COMPLETE! The environment is clean.${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
