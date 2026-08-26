#!/usr/bin/env bash
# ==============================================================================
# build_multiarch.sh - Docker Buildx Multi-Architecture Build Engine
# ==============================================================================
# Automates:
#   1. Buildx builder node provisioning (docker-container driver)
#   2. Local registry instantiation for testing OCI Manifest Lists
#   3. Dual-platform compilation (linux/amd64 and linux/arm64)
#   4. Direct loading of architecture variants into local Docker daemon
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_NAME="devops-multiarch-builder"
REGISTRY_CONTAINER="devops-local-registry"
REGISTRY_PORT="5001"
REGISTRY_IMAGE="registry:2"
IMAGE_TAG="localhost:${REGISTRY_PORT}/devops-multiarch-app:latest"

FLAG_PUSH=false
FLAG_LOAD=false
FLAG_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./build_multiarch.sh [OPTIONS]

Build multi-architecture container images (linux/amd64 and linux/arm64) with Docker Buildx.

Options:
  --push      Start a local registry on :${REGISTRY_PORT} and push a multi-arch OCI manifest list
  --load      Build and load standalone amd64 and arm64 images directly into local Docker daemon
  --clean     Teardown local registry and remove custom Buildx builder
  -h, --help  Display this help menu

Examples:
  ./build_multiarch.sh --push   # Build multi-arch image and push to local registry
  ./build_multiarch.sh --load   # Build and load devops-multiarch-app:amd64 & :arm64
  ./build_multiarch.sh --clean  # Remove builder and local registry
EOF
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)
            FLAG_PUSH=true
            shift
            ;;
        --load)
            FLAG_LOAD=true
            shift
            ;;
        --clean)
            FLAG_CLEAN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Error: Unknown option '$1'${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

teardown_resources() {
    echo -e "${CLR_YELLOW}🧹 Cleaning up multi-arch builder and local registry...${CLR_RESET}"
    if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_CONTAINER}$"; then
        docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
        echo -e "  ✔ Removed registry container '${REGISTRY_CONTAINER}'"
    fi
    docker buildx rm -f "$BUILDER_NAME" >/dev/null 2>&1 || true
    echo -e "  ✔ Removed Buildx builder '${BUILDER_NAME}'"
    docker rmi -f devops-multiarch-app:amd64 devops-multiarch-app:arm64 devops-multiarch-app:latest "$IMAGE_TAG" >/dev/null 2>&1 || true
    echo -e "${CLR_GREEN}✨ Multi-architecture build environment teardown complete.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == "true" ]]; then
    teardown_resources
    exit 0
fi

# Default to --load if neither specified
if [[ "$FLAG_PUSH" == "false" && "$FLAG_LOAD" == "false" ]]; then
    FLAG_LOAD=true
    FLAG_PUSH=true
fi

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🏗️  Docker Buildx Multi-Architecture Image Builder"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

ensure_builder() {
    echo -e "${CLR_BOLD}⚙️  Configuring Docker Buildx Builder Node...${CLR_RESET}"
    if ! docker buildx ls | grep -q "^${BUILDER_NAME}"; then
        echo -e "  Creating dedicated BuildKit builder '${BUILDER_NAME}' with docker-container driver..."
        docker buildx create --name "$BUILDER_NAME" --driver docker-container --driver-opt network=host --use >/dev/null
    else
        echo -e "  Using existing builder '${BUILDER_NAME}'..."
        docker buildx use "$BUILDER_NAME" >/dev/null
    fi
    docker buildx inspect --bootstrap >/dev/null 2>&1 || true
    echo -e "${CLR_GREEN}  ✔ Buildx builder '${BUILDER_NAME}' active and ready.${CLR_RESET}"
}

ensure_local_registry() {
    echo -e "${CLR_BOLD}📦 Ensuring Local Ephemeral OCI Registry (:5001)...${CLR_RESET}"
    if ! docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_CONTAINER}$"; then
        docker rm -f "$REGISTRY_CONTAINER" 2>/dev/null || true
        docker run -d -p "${REGISTRY_PORT}:5000" --name "$REGISTRY_CONTAINER" --restart always "$REGISTRY_IMAGE" >/dev/null
        echo -e "${CLR_GREEN}  ✔ Local registry running at http://localhost:${REGISTRY_PORT}${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}  ✔ Local registry already active on port ${REGISTRY_PORT}.${CLR_RESET}"
    fi
}

build_and_load_local() {
    echo ""
    echo -e "${CLR_BOLD}🔨 Building and loading individual platform images into Docker daemon...${CLR_RESET}"
    cd "$SCRIPT_DIR"

    echo -e "  --> Compiling ${CLR_CYAN}linux/amd64${CLR_RESET} image (devops-multiarch-app:amd64)..."
    docker buildx build \
        --platform linux/amd64 \
        -t devops-multiarch-app:amd64 \
        --load \
        .

    echo -e "  --> Compiling ${CLR_CYAN}linux/arm64${CLR_RESET} image (devops-multiarch-app:arm64)..."
    docker buildx build \
        --platform linux/arm64 \
        -t devops-multiarch-app:arm64 \
        --load \
        .

    echo -e "${CLR_GREEN}✔ Both architecture images loaded successfully into local Docker daemon!${CLR_RESET}"
}

build_and_push_multiarch() {
    echo ""
    echo -e "${CLR_BOLD}🚀 Building Multi-Architecture Manifest List (linux/amd64 + linux/arm64)...${CLR_RESET}"
    cd "$SCRIPT_DIR"

    ensure_local_registry

    echo -e "  --> Executing multi-platform build and pushing OCI Image Index to ${IMAGE_TAG}..."
    docker buildx build \
        --platform linux/amd64,linux/arm64 \
        -t "$IMAGE_TAG" \
        --push \
        .

    echo -e "${CLR_GREEN}✔ Multi-arch image index successfully built and pushed to ${IMAGE_TAG}!${CLR_RESET}"
}

main() {
    print_banner
    ensure_builder

    if [[ "$FLAG_LOAD" == "true" ]]; then
        build_and_load_local
    fi

    if [[ "$FLAG_PUSH" == "true" ]]; then
        build_and_push_multiarch
    fi

    echo ""
    echo -e "${CLR_CYAN}======================================================================${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}✨ Multi-architecture build complete! Run ./verify_architectures.sh to validate.${CLR_RESET}"
    echo -e "${CLR_CYAN}======================================================================${CLR_RESET}"
}

main
