#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 11
# ==============================================================================
# Purges:
#   1. Background port-forward processes targeting payment-service
#   2. Kubernetes namespaces (dev-environment, staging-environment, prod-environment)
#   3. Local Docker test containers and images (payment-service:*)
#   4. Ephemeral project-local temporary files and build artifacts
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
NAMESPACES=("dev-environment" "staging-environment" "prod-environment")

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Kustomize Multi-Environment Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Terminate background port-forward tunnels
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background port-forward processes...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*payment-service" 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Purge Kubernetes Namespaces
echo -e "\n${CLR_YELLOW}▶ [2/4] Purging Kubernetes environment namespaces...${CLR_RESET}"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    for ns in "${NAMESPACES[@]}"; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            echo "  Deleting namespace '${ns}' and associated pods/services/deployments..."
            kubectl delete namespace "$ns" --ignore-not-found=true --timeout=60s || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Namespace '${ns}' purged."
        else
            echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Namespace '${ns}' does not exist in cluster."
        fi
    done
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active Kubernetes cluster reachable. Skipping namespace deletion."
fi

# 3. Clean up Docker images and test containers
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging local Docker containers and images...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # Stop & remove standalone test containers
    docker rm -f payment-service-test test-kustomize-runner >/dev/null 2>&1 || true
    
    # Remove Docker images created for this project
    docker rmi -f payment-service:latest payment-service:v1.0.0 payment-service:v1.4.2 >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker test containers and images removed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker engine not reachable. Skipping container image cleanup."
fi

# 4. Remove local temporary artifacts within project directory
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary project files...${CLR_RESET}"
find "$SCRIPT_DIR" -maxdepth 3 -type f \( -name ".tmp_*" -o -name "*.log" -o -name ".test_output_*" \) -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -maxdepth 3 -type d -name ".tmp_*" -exec rm -rf {} + 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All project resources have been successfully purged.${CLR_RESET}\n"
