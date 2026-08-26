#!/usr/bin/env bash
# ==============================================================================
# test_multiarch.sh - Automated Verification Suite for Multi-Arch Buildx
# ==============================================================================
# Validates:
#   1. Docker Buildx and QEMU multi-platform emulation support
#   2. Provisioning of dedicated Buildx builder node
#   3. Dual-platform compilation (linux/amd64 & linux/arm64)
#   4. Multi-platform OCI Image Index manifest creation
#   5. Accurate runtime architecture reporting (GOARCH=amd64 & GOARCH=arm64)
#   6. Cross-platform HTTP microservice telemetry
#   7. Automated teardown and resource sanitation
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
IMAGE_TAG="localhost:${REGISTRY_PORT}/devops-multiarch-app:latest"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

FLAG_KEEP=false
FLAG_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./test_multiarch.sh [OPTIONS]

Automated test suite verifying Docker Buildx multi-architecture builds.

Options:
  --keep      Leave the local registry, builder, and test images intact after tests
  --clean     Teardown builder node, stop local registry, and delete test images
  -h, --help  Display this help menu

Examples:
  ./test_multiarch.sh          # Run full test suite with automatic cleanup
  ./test_multiarch.sh --keep   # Run tests and preserve images/registry for inspection
  ./test_multiarch.sh --clean  # Clean up all created resources
EOF
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            FLAG_KEEP=true
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

cleanup_resources() {
    echo -e "${CLR_YELLOW}🧹 Cleaning up all project containers, builders, and images...${CLR_RESET}"
    cd "$SCRIPT_DIR"
    docker rm -f "$REGISTRY_CONTAINER" 2>/dev/null || true
    docker rm -f devops-test-amd64 devops-test-arm64 2>/dev/null || true
    docker buildx rm -f "$BUILDER_NAME" 2>/dev/null || true
    docker rmi -f devops-multiarch-app:amd64 devops-multiarch-app:arm64 "$IMAGE_TAG" 2>/dev/null || true
    echo -e "${CLR_GREEN}✨ All project resources removed successfully.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == "true" ]]; then
    cleanup_resources
    exit 0
fi

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Docker Buildx Multi-Architecture Automated Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

record_result() {
    local test_num="$1"
    local description="$2"
    local status="$3"
    local details="${4:-}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$status" -eq 0 ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_GRAY}↳ ${details}${CLR_RESET}"
        fi
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_RED}↳ ${details}${CLR_RESET}"
        fi
    fi
}

run_suite() {
    print_banner
    cd "$SCRIPT_DIR"

    # --------------------------------------------------------------------------
    # Test 1: Docker Buildx Availability
    # --------------------------------------------------------------------------
    if docker buildx version >/dev/null 2>&1; then
        local bx_ver
        bx_ver=$(docker buildx version | awk '{print $2}')
        record_result "01" "Docker Buildx Engine Availability" 0 "Buildx ${bx_ver} operational"
    else
        record_result "01" "Docker Buildx Engine Availability" 1 "Docker Buildx CLI plugin not found"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 2: Buildx Multi-Arch Builder Provisioning
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Provisioning dedicated Buildx builder node...${CLR_RESET}"
    if docker buildx create --name "$BUILDER_NAME" --driver docker-container --driver-opt network=host --use >/dev/null 2>&1 || docker buildx use "$BUILDER_NAME" >/dev/null 2>&1; then
        docker buildx inspect --bootstrap >/dev/null 2>&1 || true
        record_result "02" "Buildx Builder Node Provisioning" 0 "Builder '${BUILDER_NAME}' ready with docker-container driver"
    else
        record_result "02" "Buildx Builder Node Provisioning" 1 "Failed to initialize Buildx builder"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 3: Build & Load AMD64 Target Image
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Building and loading linux/amd64 image...${CLR_RESET}"
    if docker buildx build --platform linux/amd64 -t devops-multiarch-app:amd64 --load . >/dev/null 2>&1; then
        record_result "03" "Compile and Load linux/amd64 Image" 0 "devops-multiarch-app:amd64 loaded into Docker daemon"
    else
        record_result "03" "Compile and Load linux/amd64 Image" 1 "Failed to build linux/amd64 target"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 4: Build & Load ARM64 Target Image
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Building and loading linux/arm64 image...${CLR_RESET}"
    if docker buildx build --platform linux/arm64 -t devops-multiarch-app:arm64 --load . >/dev/null 2>&1; then
        record_result "04" "Compile and Load linux/arm64 Image" 0 "devops-multiarch-app:arm64 loaded into Docker daemon"
    else
        record_result "04" "Compile and Load linux/arm64 Image" 1 "Failed to build linux/arm64 target"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 5: Build & Push Multi-Arch Manifest List
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Building and pushing dual-arch image index to local registry...${CLR_RESET}"
    docker rm -f "$REGISTRY_CONTAINER" 2>/dev/null || true
    docker run -d -p "${REGISTRY_PORT}:5000" --name "$REGISTRY_CONTAINER" registry:2 >/dev/null 2>&1
    sleep 1

    if docker buildx build --platform linux/amd64,linux/arm64 -t "$IMAGE_TAG" --push . >/dev/null 2>&1; then
        record_result "05" "Multi-Arch OCI Manifest Compilation" 0 "Pushed multi-platform index to ${IMAGE_TAG}"
    else
        record_result "05" "Multi-Arch OCI Manifest Compilation" 1 "Failed to push multi-platform manifest list"
    fi

    # --------------------------------------------------------------------------
    # Test 6: OCI Manifest List Inspection
    # --------------------------------------------------------------------------
    local inspect_out
    inspect_out=$(docker buildx imagetools inspect "$IMAGE_TAG" 2>/dev/null || echo "")
    if echo "$inspect_out" | grep -q "linux/amd64" && echo "$inspect_out" | grep -q "linux/arm64"; then
        record_result "06" "OCI Manifest List Verification" 0 "Verified both linux/amd64 and linux/arm64 in manifest index"
    else
        record_result "06" "OCI Manifest List Verification" 1 "Missing target architectures in manifest inspect"
    fi

    # --------------------------------------------------------------------------
    # Test 7: Runtime Execution on linux/amd64
    # --------------------------------------------------------------------------
    local amd64_json amd64_arch
    amd64_json=$(docker run --rm --platform linux/amd64 devops-multiarch-app:amd64 --cli 2>/dev/null || echo "{}")
    amd64_arch=$(echo "$amd64_json" | grep -o '"architecture": "[^"]*"' | cut -d'"' -f4 || echo "unknown")

    if [[ "$amd64_arch" == "amd64" ]]; then
        record_result "07" "Runtime Execution on linux/amd64" 0 "Binary reported GOARCH=amd64"
    else
        record_result "07" "Runtime Execution on linux/amd64" 1 "Expected 'amd64', got '${amd64_arch}'"
    fi

    # --------------------------------------------------------------------------
    # Test 8: Runtime Execution on linux/arm64
    # --------------------------------------------------------------------------
    local arm64_json arm64_arch
    arm64_json=$(docker run --rm --platform linux/arm64 devops-multiarch-app:arm64 --cli 2>/dev/null || echo "{}")
    arm64_arch=$(echo "$arm64_json" | grep -o '"architecture": "[^"]*"' | cut -d'"' -f4 || echo "unknown")

    if [[ "$arm64_arch" == "arm64" ]]; then
        record_result "08" "Runtime Execution on linux/arm64" 0 "Binary reported GOARCH=arm64"
    else
        record_result "08" "Runtime Execution on linux/arm64" 1 "Expected 'arm64', got '${arm64_arch}'"
    fi

    # --------------------------------------------------------------------------
    # Test 9: Cross-Architecture HTTP Microservice Telemetry
    # --------------------------------------------------------------------------
    docker rm -f devops-test-amd64 devops-test-arm64 2>/dev/null || true
    local cid_amd64 cid_arm64
    cid_amd64=$(docker run -d --name devops-test-amd64 -p 8083:8080 --platform linux/amd64 devops-multiarch-app:amd64)
    cid_arm64=$(docker run -d --name devops-test-arm64 -p 8084:8080 --platform linux/arm64 devops-multiarch-app:arm64)
    sleep 1

    local header_amd64 header_arm64
    header_amd64=$(curl -s -I http://127.0.0.1:8083/arch | grep -i "x-architecture" | tr -d '\r\n' || echo "")
    header_arm64=$(curl -s -I http://127.0.0.1:8084/arch | grep -i "x-architecture" | tr -d '\r\n' || echo "")

    docker rm -f "$cid_amd64" "$cid_arm64" >/dev/null 2>&1 || true

    if [[ "$header_amd64" =~ amd64 && "$header_arm64" =~ arm64 ]]; then
        record_result "09" "HTTP Telemetry Across Architectures" 0 "Verified X-Architecture headers (amd64 and arm64)"
    else
        record_result "09" "HTTP Telemetry Across Architectures" 1 "Headers: AMD64='$header_amd64', ARM64='$header_arm64'"
    fi

    # --------------------------------------------------------------------------
    # Test Summary & Cleanup
    # --------------------------------------------------------------------------
    echo ""
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}  📊 Test Suite Summary: ${PASSED_TESTS}/${TOTAL_TESTS} Tests Passed${CLR_RESET}"
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

    if [[ "$FLAG_KEEP" == "false" ]]; then
        cleanup_resources
    else
        echo -e "${CLR_YELLOW}ℹ️  Resources preserved for manual inspection as requested (--keep).${CLR_RESET}"
        echo -e "   Images: devops-multiarch-app:amd64, devops-multiarch-app:arm64"
        echo -e "   Registry: ${IMAGE_TAG}"
    fi

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✨ All Multi-Architecture Buildx tests passed successfully!${CLR_RESET}"
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ Some tests failed. Inspect the logs above.${CLR_RESET}"
        exit 1
    fi
}

run_suite
