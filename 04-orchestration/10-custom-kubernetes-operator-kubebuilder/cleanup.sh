#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 10
# ==============================================================================
# Purges Operator CRDs, Custom Resources, Deployments, RBAC, and Docker images.
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
OPERATOR_NS="backup-operator-system"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Kubernetes Operator & Custom Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Delete all Custom Resources
echo -e "${CLR_YELLOW}▶ [1/4] Purging ScheduledBackup custom resources...${CLR_RESET}"
if kubectl get crd scheduledbackups.backup.devops.sre.io >/dev/null 2>&1; then
    kubectl delete scheduledbackups --all -A --timeout=30s >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] ScheduledBackup custom resources deleted."
fi

# 2. Delete Operator Deployment & Namespace
echo -e "\n${CLR_YELLOW}▶ [2/4] Purging Operator namespace (${OPERATOR_NS})...${CLR_RESET}"
if kubectl get namespace "$OPERATOR_NS" >/dev/null 2>&1; then
    kubectl delete namespace "$OPERATOR_NS" --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
    # Wait until namespace is completely gone
    for _ in {1..15}; do
        if ! kubectl get namespace "$OPERATOR_NS" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Operator namespace purged."
fi

# 3. Delete RBAC & CustomResourceDefinition
echo -e "\n${CLR_YELLOW}▶ [3/4] Purging Cluster RBAC and CustomResourceDefinition...${CLR_RESET}"
kubectl delete clusterrolebinding backup-operator-manager-rolebinding --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete clusterrole backup-operator-manager-role --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete crd scheduledbackups.backup.devops.sre.io --ignore-not-found=true >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] RBAC and CRD purged."

# 4. Remove Docker image and temporary artifacts
echo -e "\n${CLR_YELLOW}▶ [4/4] Purging Docker images and temporary files...${CLR_RESET}"
docker rmi -f backup-operator:latest >/dev/null 2>&1 || true
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images and temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All Operator resources successfully purged.${CLR_RESET}\n"
