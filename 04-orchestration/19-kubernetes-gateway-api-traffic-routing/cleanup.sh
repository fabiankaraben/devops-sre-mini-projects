#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 19
# ==============================================================================
# Purges:
#   1. Background port-forward processes targeting Gateway or backends
#   2. Kubernetes namespaces: gateway-infra and gateway-apps
#   3. Gateway API v1 CRDs (GatewayClass, Gateway, HTTPRoute, ReferenceGrant)
#   4. Local Docker images (gateway-backend-app:v1.0.0, v2.0.0) and test containers
#   5. Ephemeral project-local temporary files
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Kubernetes Gateway API & Backend Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Terminate background port-forward tunnels
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background port-forward processes...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*(production-gateway|v1-service|v2-service)" 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Purge Namespaces and CRDs
echo -e "\n${CLR_YELLOW}▶ [2/4] Purging Kubernetes Namespaces & Gateway API CRDs...${CLR_RESET}"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    kubectl delete namespace gateway-infra gateway-apps --ignore-not-found=true --timeout=60s || true
    kubectl delete crd gatewayclasses.gateway.networking.k8s.io \
        gateways.gateway.networking.k8s.io \
        httproutes.gateway.networking.k8s.io \
        referencegrants.gateway.networking.k8s.io --ignore-not-found=true >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Gateway API resources and CRDs deleted."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active cluster reachable. Skipping cluster deletion."
fi

# 3. Clean up Docker images and test containers
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging local Docker test containers and images...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker rm -f gateway-backend-v1-runner gateway-backend-v2-runner test-gw-runner >/dev/null 2>&1 || true
    docker rmi -f gateway-backend-app:v1.0.0 gateway-backend-app:v2.0.0 >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker test images and containers purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker engine not reachable. Skipping image cleanup."
fi

# 4. Remove local temporary artifacts within project directory
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary project files...${CLR_RESET}"
find "$SCRIPT_DIR" -maxdepth 3 -type f \( -name ".tmp_*" -o -name "*.log" -o -name ".test_output_*" \) -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -maxdepth 3 -type d -name ".tmp_*" -exec rm -rf {} + 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All Gateway API resources successfully purged.${CLR_RESET}\n"
