#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 12
# ==============================================================================
# Purges:
#   1. Background port-forward processes targeting workload-reporter
#   2. Kubernetes namespace: scheduling-demo and all enclosed workloads
#   3. Custom node labels and taints restored to pristine baseline state
#   4. Local Docker images (workload-reporter:latest) and test containers
#   5. Temporary local test files and caches
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
NAMESPACE="scheduling-demo"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Advanced Pod Scheduling Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Terminate background port-forward tunnels
echo -e "${CLR_YELLOW}▶ [1/5] Terminating background port-forward tunnels...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*workload-reporter" 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Delete Kubernetes Namespace
echo -e "\n${CLR_YELLOW}▶ [2/5] Purging Kubernetes namespace: ${NAMESPACE}...${CLR_RESET}"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "  Deleting namespace '${NAMESPACE}' and associated pods/deployments..."
        kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=60s || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespace '${NAMESPACE}' purged."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Namespace '${NAMESPACE}' does not exist in cluster."
    fi
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active cluster reachable. Skipping namespace deletion."
fi

# 3. Restore Node Labels and Taints
echo -e "\n${CLR_YELLOW}▶ [3/5] Restoring cluster node labels and taints...${CLR_RESET}"
if [[ -f "${SCRIPT_DIR}/node_setup.sh" ]]; then
    "${SCRIPT_DIR}/node_setup.sh" --restore || true
fi

# 4. Clean up Docker images and test containers
echo -e "\n${CLR_YELLOW}▶ [4/5] Purging local Docker test containers and images...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker rm -f workload-reporter-test test-scheduling-runner >/dev/null 2>&1 || true
    docker rmi -f workload-reporter:latest >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker test images and containers purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker engine not reachable. Skipping image cleanup."
fi

# 5. Remove local temporary artifacts within project directory
echo -e "\n${CLR_YELLOW}▶ [5/5] Removing temporary project files...${CLR_RESET}"
find "$SCRIPT_DIR" -maxdepth 3 -type f \( -name ".tmp_*" -o -name "*.log" -o -name ".test_output_*" \) -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -maxdepth 3 -type d -name ".tmp_*" -exec rm -rf {} + 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: Cluster restored and all resources successfully purged.${CLR_RESET}\n"
