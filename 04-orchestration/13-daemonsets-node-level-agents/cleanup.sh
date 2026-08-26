#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 13
# ==============================================================================
# Purges:
#   1. Background port-forward processes targeting node-system-agent
#   2. Kubernetes namespace: node-monitoring and enclosed DaemonSets
#   3. ClusterRole and ClusterRoleBinding for node monitoring
#   4. Restores any cordoned cluster nodes to uncordoned state
#   5. Local Docker images (node-system-agent:*) and test containers
#   6. Ephemeral project-local temporary files
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="node-monitoring"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up DaemonSet Node Agent Mini-Project Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Terminate background port-forward tunnels
echo -e "${CLR_YELLOW}▶ [1/5] Terminating background port-forward processes...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*node-system-agent" 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Purge Kubernetes Namespace and DaemonSet
echo -e "\n${CLR_YELLOW}▶ [2/5] Purging Kubernetes namespace: ${NAMESPACE}...${CLR_RESET}"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "  Deleting namespace '${NAMESPACE}' and associated DaemonSets/Pods..."
        kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=60s || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespace '${NAMESPACE}' purged."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Namespace '${NAMESPACE}' does not exist in cluster."
    fi

    # 3. Purge ClusterRole & Binding
    echo -e "\n${CLR_YELLOW}▶ [3/5] Purging ClusterRole and ClusterRoleBinding...${CLR_RESET}"
    kubectl delete clusterrolebinding node-agent-rolebinding --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete clusterrole node-agent-role --ignore-not-found=true >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cluster-level RBAC resources purged."

    # Uncordon nodes if any were left cordoned
    NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    for n in $NODES; do
        kubectl uncordon "$n" >/dev/null 2>&1 || true
    done
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active cluster reachable. Skipping namespace/RBAC deletion."
fi

# 4. Clean up Docker images and test containers
echo -e "\n${CLR_YELLOW}▶ [4/5] Purging local Docker test containers and images...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker rm -f node-agent-test test-daemonset-runner >/dev/null 2>&1 || true
    docker rmi -f node-system-agent:v1.0.0 node-system-agent:v2.0.0 >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker test images and containers purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker engine not reachable. Skipping image cleanup."
fi

# 5. Remove local temporary artifacts within project directory
echo -e "\n${CLR_YELLOW}▶ [5/5] Removing temporary project files...${CLR_RESET}"
find "$SCRIPT_DIR" -maxdepth 3 -type f \( -name ".tmp_*" -o -name "*.log" -o -name ".test_output_*" \) -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -maxdepth 3 -type d -name ".tmp_*" -exec rm -rf {} + 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All DaemonSet resources successfully purged.${CLR_RESET}\n"
