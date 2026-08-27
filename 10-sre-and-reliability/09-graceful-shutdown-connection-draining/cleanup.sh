#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Complete Resource Teardown for Mini-Project 10-09
# ==============================================================================
# Purges local K3d cluster, Docker Compose containers, container images,
# isolated .kubeconfig, and generated load test reports.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

CLUSTER_NAME="k3d-graceful-demo"
IMAGE_NAME="sre-graceful-app:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_ALL=false

for arg in "$@"; do
    case "$arg" in
        --all|--purge)
            PURGE_ALL=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge      Delete K3d cluster ($CLUSTER_NAME), Docker images, and all artifacts"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./cleanup.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up Graceful Shutdown & Connection Draining Stack"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Stop Docker Compose containers
echo -e "${CLR_YELLOW}▶ [1/4] Stopping Docker Compose containers...${CLR_RESET}"
if command -v docker >/dev/null 2>&1; then
    docker compose down --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker containers stopped."
fi

# 2. Teardown or Purge K3d Cluster
echo -e "\n${CLR_YELLOW}▶ [2/4] Managing K3d cluster '$CLUSTER_NAME'...${CLR_RESET}"
if command -v k3d >/dev/null 2>&1; then
    if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        if [ "$PURGE_ALL" = true ]; then
            echo -e "  Deleting K3d cluster '$CLUSTER_NAME'..."
            k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cluster '$CLUSTER_NAME' deleted."
        else
            echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Cluster kept running. (Use ./cleanup.sh --all to delete cluster)."
        fi
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Cluster '$CLUSTER_NAME' does not exist."
    fi
fi

# 3. Purge Docker images
if [ "$PURGE_ALL" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [3/4] Purging Docker image ($IMAGE_NAME)...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1 && docker images -q "$IMAGE_NAME" 2>/dev/null | grep -q .; then
        docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Image '$IMAGE_NAME' removed."
    else
        echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Image '$IMAGE_NAME' not found or already deleted."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [3/4] Skipping image deletion (use --all to purge Docker images).${CLR_RESET}"
fi

# 4. Clean local caches, reports, and isolated .kubeconfig
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing reports, temporary logs, and isolated .kubeconfig...${CLR_RESET}"
rm -rf "$SCRIPT_DIR/reports"
rm -f "$SCRIPT_DIR/.kubeconfig"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local artifacts and reports cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment teardown complete! Ready for subsequent projects.${CLR_RESET}\n"
