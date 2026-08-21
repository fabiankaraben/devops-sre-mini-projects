#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 02
# ==============================================================================
# Purges all Kubernetes resources, namespaces, background port-forward tunnels,
# local Docker test containers, and container images created by this project.
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
NAMESPACE="config-reloading-demo"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up ConfigMaps & Secrets Reloading Project Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Kill background port-forward processes targeting this project
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background port-forward tunnels...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*config-reloading" || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Delete Kubernetes Namespace and all enclosed resources
echo -e "\n${CLR_YELLOW}▶ [2/4] Purging Kubernetes namespace: ${NAMESPACE}...${CLR_RESET}"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "  Deleting namespace ${NAMESPACE} and associated pods/services/deployments/configmaps/secrets..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=60s
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kubernetes namespace ${NAMESPACE} purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Namespace ${NAMESPACE} does not exist in cluster."
fi

# 3. Clean up Docker images and test containers
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging local Docker containers and images...${CLR_RESET}"
docker rm -f config-reloading-test test-config-runner >/dev/null 2>&1 || true
docker rmi -f config-reloading-app:v1.0.0 >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker test containers and images removed."

# 4. Remove local temporary artifacts within project directory
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary project files...${CLR_RESET}"
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".reload_results_*" -o -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All project resources have been successfully purged.${CLR_RESET}\n"
