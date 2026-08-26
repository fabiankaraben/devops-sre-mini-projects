#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown & Resource Cleanup Script for Mini-Project 06
# ==============================================================================
# Purges:
#   1. Background port-forward processes (ArgoCD, Git Server, Target Webapp)
#   2. Kubernetes Application & ArgoCD namespaces (if running on external cluster)
#   3. k3d Cluster (gitops-argocd-cluster) including Docker containers & volumes
#   4. Dangling Docker resources and networks associated with the cluster
#   5. Local temporary sandbox files (.tmp_sandbox, test logs, manifests)
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
CLUSTER_NAME="gitops-argocd-cluster"
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"

KEEP_CLUSTER=false

show_help() {
    cat <<EOF
Usage: ./cleanup.sh [OPTIONS]

Tears down the k3d cluster, ArgoCD workloads, Docker containers, and test sandboxes.

Options:
  --keep-cluster   Retain the k3d cluster and only delete namespaces & port-forwards
  -h, --help       Display this help message

Examples:
  ./cleanup.sh                # Complete teardown of all local cluster & Docker resources
  ./cleanup.sh --keep-cluster # Clean application namespaces but leave k3d cluster running
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-cluster)
            KEEP_CLUSTER=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up GitOps ArgoCD Resources & Docker Environment"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Terminate background port-forward tunnels
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background port-forward tunnels...${CLR_RESET}"
PIDS=$(pgrep -f "port-forward.*(argocd|git-server|gitops-webapp)" || true)
if [[ -n "$PIDS" ]]; then
    echo "  Killing port-forward process(es): $PIDS"
    # shellcheck disable=SC2086
    kill -9 $PIDS 2>/dev/null || true
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Port-forward processes terminated."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active port-forward processes found."
fi

# 2. Clean Kubernetes namespaces (if cluster is accessible)
if kubectl get nodes >/dev/null 2>&1; then
    echo -e "\n${CLR_YELLOW}▶ [2/4] Removing Kubernetes namespaces & ArgoCD Application...${CLR_RESET}"
    
    # Delete ArgoCD Application first to trigger graceful finalizer cleanup
    if kubectl get application gitops-webapp -n argocd >/dev/null 2>&1; then
        echo "  Deleting ArgoCD Application 'gitops-webapp'..."
        kubectl delete application gitops-webapp -n argocd --timeout=30s --ignore-not-found=true || true
    fi

    for ns in gitops-demo gitops-system argocd; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            echo "  Purging namespace: ${ns}..."
            kubectl delete namespace "$ns" --ignore-not-found=true --timeout=45s || true
            echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Namespace '${ns}' deleted."
        fi
    done
else
    echo -e "\n${CLR_YELLOW}▶ [2/4] Kubernetes cluster unreachable or already stopped. Skipping namespace deletion.${CLR_RESET}"
fi

# 3. Delete k3d cluster and associated Docker resources
echo -e "\n${CLR_YELLOW}▶ [3/4] Tearing down k3d cluster and Docker containers...${CLR_RESET}"
if [[ "$KEEP_CLUSTER" == false ]]; then
    if command -v k3d >/dev/null 2>&1; then
        if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
            echo "  Deleting k3d cluster '${CLUSTER_NAME}'..."
            k3d cluster delete "$CLUSTER_NAME"
            echo -e "  [${CLR_GREEN}✓${CLR_RESET}] k3d cluster '${CLUSTER_NAME}' deleted."
        else
            echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] k3d cluster '${CLUSTER_NAME}' does not exist."
        fi
    fi

    # Prune any orphaned containers or networks prefixed with k3d-gitops-argocd
    ORPHAN_CONTAINERS=$(docker ps -a --filter "name=k3d-${CLUSTER_NAME}" -q 2>/dev/null || true)
    if [[ -n "$ORPHAN_CONTAINERS" ]]; then
        echo "  Removing orphaned containers: $ORPHAN_CONTAINERS"
        # shellcheck disable=SC2086
        docker rm -f $ORPHAN_CONTAINERS >/dev/null 2>&1 || true
    fi

    ORPHAN_VOLUMES=$(docker volume ls --filter "name=k3d-${CLUSTER_NAME}" -q 2>/dev/null || true)
    if [[ -n "$ORPHAN_VOLUMES" ]]; then
        echo "  Removing orphaned Docker volumes: $ORPHAN_VOLUMES"
        # shellcheck disable=SC2086
        docker volume rm -f $ORPHAN_VOLUMES >/dev/null 2>&1 || true
    fi
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Docker containers and volumes purged."
else
    echo -e "  [${CLR_BLUE}INFO${CLR_RESET}] Retaining k3d cluster '${CLUSTER_NAME}' (--keep-cluster specified)."
fi

# 4. Clean local sandbox files
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary files and local test sandboxes...${CLR_RESET}"
if [[ -d "$SANDBOX_DIR" ]]; then
    rm -rf "$SANDBOX_DIR"
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Sandbox directory '${SANDBOX_DIR}' removed."
fi
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Temporary files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ CLEANUP COMPLETE: All GitOps resources successfully purged!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
