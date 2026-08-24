#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Complete Resource Teardown for Mini-Project 12-08
# ==============================================================================
# Deletes Kubernetes Cluster CRDs, MinIO deployments, secrets, and tears down
# the dedicated local k3d cluster (cnpg-lab), leaving the workstation 100% clean.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_IMAGES=false
KEEP_CLUSTER=false
CLUSTER_NAME="cnpg-lab"

for arg in "$@"; do
    case "$arg" in
        --all|--purge-images)
            PURGE_IMAGES=true
            ;;
        --keep-cluster)
            KEEP_CLUSTER=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-images   Remove CNPG, PostgreSQL, and MinIO container images"
            echo "  --keep-cluster          Keep the k3d cluster running (delete only CNPG objects)"
            echo "  --help, -h              Show this help message"
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
echo "  🧹 CloudNative-PG Operator - Environment Teardown"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Delete Kubernetes CRDs & Manifests
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Removing Kubernetes database manifests & secrets...${CLR_RESET}"

if command -v kubectl >/dev/null 2>&1; then
    kubectl delete -f "$SCRIPT_DIR/manifests/04-backup.yaml" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -f "$SCRIPT_DIR/manifests/03-cluster.yaml" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -f "$SCRIPT_DIR/manifests/02-secrets.yaml" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -f "$SCRIPT_DIR/manifests/01-minio-s3.yaml" --ignore-not-found >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Kubernetes database and backup manifests removed."
fi

# ------------------------------------------------------------------------------
# 2. Teardown Local k3d Cluster
# ------------------------------------------------------------------------------
if [ "$KEEP_CLUSTER" = false ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Deleting dedicated k3d cluster '${CLUSTER_NAME}'...${CLR_RESET}"
    if command -v k3d >/dev/null 2>&1; then
        if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
            k3d cluster delete "${CLUSTER_NAME}" >/dev/null 2>&1 || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] k3d cluster '${CLUSTER_NAME}' deleted."
        else
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] k3d cluster '${CLUSTER_NAME}' was already deleted."
        fi
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping cluster teardown (--keep-cluster specified).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Optionally Purge Docker Container Images & Clean Local Files
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [3/3] Purging CloudNative-PG, PostgreSQL, and MinIO container images...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f ghcr.io/cloudnative-pg/postgresql:16.4 \
                      ghcr.io/cloudnative-pg/cloudnative-pg:v1.25.0 \
                      minio/minio:latest \
                      minio/mc:latest >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images purged."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [3/3] Skipping image deletion (use --all or --purge-images to delete images).${CLR_RESET}"
fi

rm -rf "$SCRIPT_DIR/backups" "$SCRIPT_DIR/reports" "$SCRIPT_DIR"/*.log "$SCRIPT_DIR"/*.tmp
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files, logs, and python caches cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
