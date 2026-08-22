#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource & Container Cleanup for Mini-Project 02
# ==============================================================================
# Purges:
#   1. Local OCI registry containers (multiarch-test-registry)
#   2. Multi-arch test containers (multiarch-service-test)
#   3. Ephemeral Docker Buildx builder instances
#   4. Dangling test images and temporary caches
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PURGE_IMAGES=false

show_help() {
    cat <<EOF
Usage: ./cleanup.sh [OPTIONS]

Cleanup script for Multi-Arch Docker Build and Push Pipeline.

Options:
  --images    Also prune test images tagged during local verification
  -h, --help  Display this help message

Examples:
  ./cleanup.sh          # Clean test containers, registry, and buildx builders
  ./cleanup.sh --images # Clean containers, builders, and tagged test images
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --images)
            PURGE_IMAGES=true
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

echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}🧹 Cleaning Up Multi-Arch Pipeline Test Resources...${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    # 1. Stop and remove test registry and microservice containers
    echo -e "${CLR_YELLOW}[1/4] Removing test containers & local registry...${CLR_RESET}"
    CONTAINERS=$(docker ps -a --filter "name=multiarch-" --format "{{.ID}}" 2>/dev/null || true)
    if [[ -n "$CONTAINERS" ]]; then
        docker rm -f $CONTAINERS >/dev/null 2>&1 || true
        echo -e "${CLR_GREEN}✓ Removed active/stopped test containers.${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}✓ No test containers found.${CLR_RESET}"
    fi

    # 2. Remove ephemeral Buildx builders
    echo -e "${CLR_YELLOW}[2/4] Removing ephemeral Buildx test builders...${CLR_RESET}"
    if docker buildx ls 2>/dev/null | grep -q "multiarch-test-builder"; then
        docker buildx rm multiarch-test-builder >/dev/null 2>&1 || true
        echo -e "${CLR_GREEN}✓ Removed multiarch-test-builder instance.${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}✓ No custom Buildx test builders found.${CLR_RESET}"
    fi

    # 3. Optional image purge
    if [[ "$PURGE_IMAGES" == "true" ]]; then
        echo -e "${CLR_YELLOW}[3/4] Pruning test images...${CLR_RESET}"
        docker rmi localhost:5055/multiarch-demo:test >/dev/null 2>&1 || true
        docker rmi multiarch-demo:local >/dev/null 2>&1 || true
        echo -e "${CLR_GREEN}✓ Test images pruned.${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}[3/4] Skipping image pruning (use --images to remove tagged test images).${CLR_RESET}"
    fi
else
    echo -e "${CLR_YELLOW}Docker not found; skipping container teardown.${CLR_RESET}"
fi

# 4. Clean local temporary files
echo -e "${CLR_YELLOW}[4/4] Purging local coverage outputs and temporary test logs...${CLR_RESET}"
rm -rf "${SCRIPT_DIR}/app/coverage.out"
rm -rf "${SCRIPT_DIR}/.tmp_build"
echo -e "${CLR_GREEN}✓ Local test files removed.${CLR_RESET}"

echo -e "\n${CLR_BOLD}${CLR_GREEN}✨ Environment cleanup complete! The workspace is pristine.${CLR_RESET}\n"
