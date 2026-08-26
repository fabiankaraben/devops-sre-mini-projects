#!/usr/bin/env bash
# ==============================================================================
# bootstrap_static_pods.sh - Static Pod Manifest Deployment & Discovery Utility
# ==============================================================================
# Discovers the active Kubelet static pod manifest directory on the host/cluster
# node and manages the static pod lifecycle directly on the filesystem:
#
# Supported static pod paths:
#   - Kubeadm / Standard Kubernetes: /etc/kubernetes/manifests
#   - K3s / K3d: /var/lib/rancher/k3s/agent/pod-manifests
#   - Custom / Local testing directory
#
# Commands:
#   --deploy  : Injects static pod manifests into the Kubelet directory (default)
#   --list    : Lists static pod manifests in Kubelet directory
#   --remove  : Removes static pod manifests from the Kubelet directory
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/static-manifests"
STATIC_MANIFEST="static-diagnostics-web.yaml"

# Target search paths in priority order
CANDIDATE_PATHS=(
    "/etc/kubernetes/manifests"
    "/var/lib/rancher/k3s/agent/pod-manifests"
)

detect_static_path() {
    # Check if a live node container exists (k3d/kind)
    if command -v docker >/dev/null 2>&1; then
        local node_container
        node_container=$(docker ps --format '{{.Names}}' | grep -E 'k3d-.*-server-0|kind-control-plane' | head -n1 || echo "")
        if [[ -n "$node_container" ]]; then
            echo "CONTAINER:${node_container}"
            return 0
        fi
    fi

    for p in "${CANDIDATE_PATHS[@]}"; do
        if [[ -d "$p" && -w "$p" ]]; then
            echo "HOST:${p}"
            return 0
        fi
    done

    # Fallback to local simulation mode
    echo "LOCAL:${SCRIPT_DIR}/.local_kubelet_manifests"
}

ACTION="${1:---deploy}"

case "$ACTION" in
    --deploy)
        echo -e "${CLR_CYAN}${CLR_BOLD}"
        echo "======================================================================"
        echo "  📦 Deploying Static Pod Manifest to Kubelet Watch Directory"
        echo "======================================================================"
        echo -e "${CLR_RESET}"

        LOCATION=$(detect_static_path)
        TYPE="${LOCATION%%:*}"
        TARGET="${LOCATION#*:}"

        echo -e "  Detected Environment Target: ${CLR_MAGENTA}${TYPE}${CLR_RESET} (${TARGET})"

        if [[ "$TYPE" == "CONTAINER" ]]; then
            echo "  Copying static manifest into control-plane container '${TARGET}'..."
            docker exec "$TARGET" mkdir -p /var/lib/rancher/k3s/agent/pod-manifests /etc/kubernetes/manifests 2>/dev/null || true
            docker cp "${SOURCE_DIR}/${STATIC_MANIFEST}" "${TARGET}:/var/lib/rancher/k3s/agent/pod-manifests/${STATIC_MANIFEST}" 2>/dev/null || \
            docker cp "${SOURCE_DIR}/${STATIC_MANIFEST}" "${TARGET}:/etc/kubernetes/manifests/${STATIC_MANIFEST}" 2>/dev/null || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Static manifest injected into containerized node."
        elif [[ "$TYPE" == "HOST" ]]; then
            echo "  Copying static manifest to host path '${TARGET}'..."
            cp "${SOURCE_DIR}/${STATIC_MANIFEST}" "${TARGET}/${STATIC_MANIFEST}"
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Static manifest placed in '${TARGET}'."
        else
            mkdir -p "$TARGET"
            cp "${SOURCE_DIR}/${STATIC_MANIFEST}" "${TARGET}/${STATIC_MANIFEST}"
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Static manifest placed in simulated directory '${TARGET}'."
        fi

        echo -e "\n  ${CLR_GREEN}Static pod manifest is now active.${CLR_RESET} Local Kubelet will supervise the pod directly.\n"
        ;;

    --list)
        echo -e "${CLR_CYAN}${CLR_BOLD}"
        echo "======================================================================"
        echo "  📋 Active Static Pod Manifests"
        echo "======================================================================"
        echo -e "${CLR_RESET}"
        LOCATION=$(detect_static_path)
        TYPE="${LOCATION%%:*}"
        TARGET="${LOCATION#*:}"

        if [[ "$TYPE" == "CONTAINER" ]]; then
            echo "  Files in container '${TARGET}':"
            docker exec "$TARGET" ls -la /var/lib/rancher/k3s/agent/pod-manifests 2>/dev/null || docker exec "$TARGET" ls -la /etc/kubernetes/manifests 2>/dev/null || echo "  (none)"
        else
            if [[ -d "$TARGET" ]]; then
                ls -la "$TARGET"
            else
                echo "  Directory '${TARGET}' does not exist."
            fi
        fi
        ;;

    --remove)
        echo -e "${CLR_YELLOW}${CLR_BOLD}"
        echo "======================================================================"
        echo "  🧹 Removing Static Pod Manifest from Kubelet Watch Directory"
        echo "======================================================================"
        echo -e "${CLR_RESET}"
        LOCATION=$(detect_static_path)
        TYPE="${LOCATION%%:*}"
        TARGET="${LOCATION#*:}"

        if [[ "$TYPE" == "CONTAINER" ]]; then
            docker exec "$TARGET" rm -f "/var/lib/rancher/k3s/agent/pod-manifests/${STATIC_MANIFEST}" "/etc/kubernetes/manifests/${STATIC_MANIFEST}" 2>/dev/null || true
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Static manifest removed from container '${TARGET}'."
        elif [[ "$TYPE" == "HOST" ]]; then
            rm -f "${TARGET}/${STATIC_MANIFEST}"
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Static manifest removed from host '${TARGET}'."
        else
            rm -rf "$TARGET"
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Simulated directory removed."
        fi
        ;;

    *)
        echo "Usage: $0 [--deploy | --list | --remove]"
        exit 1
        ;;
esac
