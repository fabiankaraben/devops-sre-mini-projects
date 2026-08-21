#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 09
# ==============================================================================
# Purges all zero-trust namespaces, workloads, policies, Docker images & temp files.
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
NAMESPACES=("tenant-frontend" "tenant-backend" "tenant-database" "tenant-untrusted")

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Zero-Trust Network Resources & Namespaces"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Terminate active port-forwards
echo -e "${CLR_YELLOW}▶ [1/3] Terminating background port-forward processes...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*tenant" || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward PID(s): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Delete tenant namespaces (cascades Deployments, Services, NetworkPolicies, and Pods)
echo -e "\n${CLR_YELLOW}▶ [2/3] Purging tenant namespaces...${CLR_RESET}"
for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        kubectl delete namespace "$ns" --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
        # Wait until namespace is completely gone
        for _ in {1..15}; do
            if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Purged namespace: ${ns}"
    fi
done

# 3. Purge Docker images & temp files
echo -e "\n${CLR_YELLOW}▶ [3/3] Purging Docker images and temporary files...${CLR_RESET}"
docker rmi -f zero-trust-app:latest >/dev/null 2>&1 || true
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images and temporary artifacts removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All Zero-Trust resources successfully purged.${CLR_RESET}\n"
