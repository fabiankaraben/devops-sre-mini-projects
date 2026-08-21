#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 08
# ==============================================================================
# Purges Argo Rollouts, AnalysisRuns, namespaces, Docker images, and temp files.
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
DEMO_NS="argo-rollouts-demo"
CONTROLLER_NS="argo-rollouts"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Argo Rollouts & Kubernetes Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Kill background port-forwards
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background port-forward tunnels...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*rollout" || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Delete demo namespace
echo -e "\n${CLR_YELLOW}▶ [2/4] Purging demo namespace (${DEMO_NS})...${CLR_RESET}"
if kubectl get namespace "$DEMO_NS" >/dev/null 2>&1; then
    kubectl delete namespace "$DEMO_NS" --ignore-not-found=true --timeout=60s
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespace ${DEMO_NS} purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Namespace ${DEMO_NS} does not exist."
fi

# 3. Delete controller namespace
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging Argo Rollouts controller namespace (${CONTROLLER_NS})...${CLR_RESET}"
if kubectl get namespace "$CONTROLLER_NS" >/dev/null 2>&1; then
    kubectl delete namespace "$CONTROLLER_NS" --ignore-not-found=true --timeout=60s
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespace ${CONTROLLER_NS} purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Namespace ${CONTROLLER_NS} does not exist."
fi

# 4. Remove Docker images & temporary files
echo -e "\n${CLR_YELLOW}▶ [4/4] Purging local Docker images and temporary files...${CLR_RESET}"
docker rmi -f rollout-app:v1.0.0 rollout-app:v2.0.0 rollout-app:v2-faulty >/dev/null 2>&1 || true
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images and temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All Argo Rollouts resources successfully purged.${CLR_RESET}\n"
