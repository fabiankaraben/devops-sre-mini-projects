#!/usr/bin/env bash
# ==============================================================================
# setup_argo_rollouts.sh - Argo Rollouts Controller Installer & Initializer
# ==============================================================================
# Installs Argo Rollouts CRDs & Controller and waits for controller readiness.
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
INSTALL_YAML="${SCRIPT_DIR}/install/argo-rollouts-install.yaml"
ARGO_NAMESPACE="argo-rollouts"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 Argo Rollouts Controller Setup & Health Check"
echo "======================================================================"
echo -e "${CLR_RESET}"

echo -e "${CLR_YELLOW}▶ Step 1: Checking Argo Rollouts Controller status...${CLR_RESET}"
if kubectl get deployment argo-rollouts -n "$ARGO_NAMESPACE" >/dev/null 2>&1; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Argo Rollouts deployment already exists."
else
    echo "  Creating namespace '${ARGO_NAMESPACE}' and applying controller manifests..."
    kubectl create namespace "$ARGO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    if [[ -f "$INSTALL_YAML" ]]; then
        kubectl apply -n "$ARGO_NAMESPACE" -f "$INSTALL_YAML" >/dev/null
    else
        kubectl apply -n "$ARGO_NAMESPACE" -f "https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/install.yaml" >/dev/null
    fi
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Argo Rollouts CRDs & Controller installed."
fi

echo -e "\n${CLR_YELLOW}▶ Step 2: Waiting for controller pod readiness...${CLR_RESET}"
kubectl rollout status deployment/argo-rollouts -n "$ARGO_NAMESPACE" --timeout=90s >/dev/null

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Argo Rollouts controller is active and ready."
echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ ARGO ROLLOUTS SETUP COMPLETE!${CLR_RESET}\n"
