#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Standalone Teardown and Sanitation Script
# ==============================================================================
# Purges the K3d Kubernetes cluster, Pulumi local state, local kubeconfigs,
# temporary build outputs, and logs to leave a clean environment.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NAME="k3d-pulumi-demo"
PURGE_ALL=false

for arg in "$@"; do
    case "$arg" in
        --all)
            PURGE_ALL=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all      Purge node_modules, build caches, cluster, and state"
            echo "  --help, -h Show this help message"
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
echo "  🧹 Cleaning Up Pulumi TypeScript Kubernetes Infrastructure"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Delete K3d cluster and associated Docker resources
echo -e "${CLR_YELLOW}▶ [1/4] Deleting K3d cluster (${CLUSTER_NAME})...${CLR_RESET}"
if command -v k3d >/dev/null 2>&1; then
    if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME} "; then
        k3d cluster delete "${CLUSTER_NAME}" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] K3d cluster '${CLUSTER_NAME}' deleted."
    else
        echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] K3d cluster '${CLUSTER_NAME}' not running."
    fi
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] k3d CLI not available."
fi

# Step 2: Remove local Kubeconfig and Pulumi state backends
echo -e "\n${CLR_YELLOW}▶ [2/4] Purging local state backends and credentials...${CLR_RESET}"
rm -rf .kube .pulumi_home .pulumi_backend .pulumi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local state backends and kubeconfig removed."

# Step 3: Remove build artifacts and logs
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging TypeScript build output and execution logs...${CLR_RESET}"
rm -rf dist logs/ *.log .tsbuildinfo
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Build artifacts and logs cleared."

# Step 4: Remove node_modules if --all requested
echo -e "\n${CLR_YELLOW}▶ [4/4] Managing dependencies...${CLR_RESET}"
if [[ "$PURGE_ALL" == true ]]; then
    rm -rf node_modules
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] node_modules removed (--all active)."
else
    echo -e "  [${CLR_GREEN}INFO${CLR_RESET}] node_modules retained for quick subsequent runs."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: Environment is clean and ready for subsequent mini-projects.${CLR_RESET}\n"
