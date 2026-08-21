#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 06
# ==============================================================================
# Uninstalls Helm releases, purges namespaces, local Docker images, and temp files.
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
NAMESPACE="helm-demo"
RELEASE_NAME="enterprise-app"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Helm 3 Release & Kubernetes Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Kill background port-forward processes
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background port-forward tunnels...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*enterprise" || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Uninstall Helm release
echo -e "\n${CLR_YELLOW}▶ [2/4] Uninstalling Helm release: ${RELEASE_NAME}...${CLR_RESET}"
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --timeout 30s >/dev/null
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Helm release ${RELEASE_NAME} uninstalled."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Helm release ${RELEASE_NAME} not found."
fi

# 3. Delete Namespace
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging Kubernetes namespace: ${NAMESPACE}...${CLR_RESET}"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "  Deleting namespace ${NAMESPACE}..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=60s
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kubernetes namespace ${NAMESPACE} purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Namespace ${NAMESPACE} does not exist in cluster."
fi

# 4. Clean up Docker images & temporary files
echo -e "\n${CLR_YELLOW}▶ [4/4] Purging local Docker images and temporary files...${CLR_RESET}"
docker rm -f helm-test-runner >/dev/null 2>&1 || true
docker rmi -f enterprise-app:v1.0.0 >/dev/null 2>&1 || true

find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images and temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All Helm releases & resources successfully purged.${CLR_RESET}\n"
