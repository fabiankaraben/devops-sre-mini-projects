#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Teardown & Resource Cleanup for Mini-Project 08
# ==============================================================================
# Purges:
#   1. Local k3d cluster (preview-env-cluster)
#   2. Local container images (preview-app:v1.0.0, preview-app:v2.0.0)
#   3. Local test sandboxes (.tmp_sandbox/, kubeconfig.yaml, test logs)
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
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"
CLUSTER_NAME="preview-env-cluster"

KEEP_IMAGES=false

show_help() {
    cat <<EOF
Usage: ./cleanup.sh [OPTIONS]

Stops and removes the k3d preview cluster, Docker images, and temporary files.

Options:
  --keep-images   Retain built Docker images for fast subsequent runs
  -h, --help      Display this help message

Examples:
  ./cleanup.sh               # Complete purge of k3d cluster, images, and sandboxes
  ./cleanup.sh --keep-images # Purge k3d cluster and sandboxes, retain Docker images
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-images)
            KEEP_IMAGES=true
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
echo "  🧹 Cleaning Up Ephemeral Preview Cluster & Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Delete k3d cluster
echo -e "${CLR_YELLOW}▶ [1/3] Deleting k3d cluster '${CLUSTER_NAME}'...${CLR_RESET}"
if command -v k3d >/dev/null 2>&1; then
    if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
        k3d cluster delete "$CLUSTER_NAME"
        echo -e "  [${CLR_GREEN}✓${CLR_RESET}] k3d cluster '${CLUSTER_NAME}' deleted."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active cluster '${CLUSTER_NAME}' found."
    fi
fi

# 2. Clean Docker Images and residual containers
echo -e "\n${CLR_YELLOW}▶ [2/3] Removing preview application Docker images...${CLR_RESET}"
if [[ "$KEEP_IMAGES" == false ]]; then
    docker rmi -f preview-app:v1.0.0 preview-app:v2.0.0 >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Application Docker images purged."
else
    echo -e "  [${CLR_BLUE}INFO${CLR_RESET}] Keeping Docker images (--keep-images flag passed)."
fi

# 3. Clean temporary sandboxes & logs
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing local sandbox directory and temporary files...${CLR_RESET}"
if [[ -d "$SANDBOX_DIR" ]]; then
    rm -rf "$SANDBOX_DIR"
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Sandbox directory '${SANDBOX_DIR}' removed."
fi
find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".tmp_*" -o -name "*.log" -o -name "kubeconfig.yaml" \) -exec rm -f {} +
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Temporary files cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ CLEANUP COMPLETE: All preview cluster resources purged!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
