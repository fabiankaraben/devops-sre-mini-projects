#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 10-07 (Chaos Mesh)
# ==============================================================================
# Cleans up chaos experiments, target workloads, Helm releases, namespaces,
# and optionally deletes the local K3d cluster, leaving the environment clean.
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

CLUSTER_NAME="k3d-chaos-mesh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export KUBECONFIG="$SCRIPT_DIR/.kubeconfig"

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
            echo "  --all, --delete-cluster   Delete the entire local K3d cluster ($CLUSTER_NAME) and Docker containers"
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
echo "  🧹 Cleaning Up Kubernetes Chaos Mesh Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

if [ "$DELETE_CLUSTER" = true ]; then
    echo -e "${CLR_YELLOW}▶ [1/2] Deleting K3d cluster '$CLUSTER_NAME' and container infrastructure...${CLR_RESET}"
    if command -v k3d >/dev/null 2>&1 && k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -q "^${CLUSTER_NAME}$"; then
        k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] K3d cluster '$CLUSTER_NAME' and associated containers/volumes deleted."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Cluster '$CLUSTER_NAME' not found or already deleted."
    fi
else
    echo -e "${CLR_YELLOW}▶ [1/2] Removing chaos experiments, namespaces, and Helm releases...${CLR_RESET}"
    if command -v kubectl >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/.kubeconfig" ]; then
        # Delete experiments first to stop active faults
        kubectl delete podchaos,networkchaos,stresschaos,timechaos,workflow --all --all-namespaces --timeout=15s >/dev/null 2>&1 || true

        # Delete application and chaos mesh namespaces
        kubectl delete namespace chaos-lab --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true

        if command -v helm >/dev/null 2>&1; then
            helm uninstall chaos-mesh -n chaos-mesh >/dev/null 2>&1 || true
        fi
        kubectl delete namespace chaos-mesh --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Application and Chaos Mesh namespaces removed (use --all to delete K3d cluster)."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active cluster or kubeconfig found."
    fi
fi

# Clean local temporary files
echo -e "\n${CLR_YELLOW}▶ [2/2] Cleaning local temporary reports, logs, and isolated kubeconfig...${CLR_RESET}"
rm -f "$SCRIPT_DIR/.kubeconfig" "$SCRIPT_DIR/chaos_report.md" "$SCRIPT_DIR/chaos_report.json"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local artifacts cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
