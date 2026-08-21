#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown and Cleanup Script for Mini-Project 07
# ==============================================================================
# Purges RBAC ClusterRoles, ClusterRoleBindings, namespaces, and temp files.
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
echo "  🧹 Cleaning Up RBAC & Pod Security Policy Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Delete Cluster-Wide RBAC Objects
echo -e "${CLR_YELLOW}▶ [1/3] Purging ClusterRole & ClusterRoleBinding objects...${CLR_RESET}"
kubectl delete clusterrolebinding cluster-auditor-binding --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
kubectl delete clusterrole cluster-auditor-role --ignore-not-found=true --timeout=30s >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cluster-level RBAC objects removed."

# 2. Delete Namespaces
echo -e "\n${CLR_YELLOW}▶ [2/3] Purging Kubernetes namespaces (security-dev, security-restricted, security-baseline)...${CLR_RESET}"
kubectl delete namespace security-dev --ignore-not-found=true --timeout=60s >/dev/null 2>&1 || true
kubectl delete namespace security-restricted --ignore-not-found=true --timeout=60s >/dev/null 2>&1 || true
kubectl delete namespace security-baseline --ignore-not-found=true --timeout=60s >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kubernetes namespaces purged."

# 3. Clean temporary files
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing temporary files...${CLR_RESET}"
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All RBAC policies & security namespaces successfully purged.${CLR_RESET}\n"
