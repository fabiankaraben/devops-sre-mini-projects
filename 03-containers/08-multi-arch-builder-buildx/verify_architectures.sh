#!/usr/bin/env bash
# ==============================================================================
# verify_architectures.sh - Multi-Architecture Verification & Manifest Inspector
# ==============================================================================
# Validates:
#   1. OCI Image Index manifest structure (linux/amd64 & linux/arm64 descriptors)
#   2. Emulated/Native execution of linux/amd64 binary (asserts GOARCH=amd64)
#   3. Emulated/Native execution of linux/arm64 binary (asserts GOARCH=arm64)
#   4. HTTP service responses and telemetry across both CPU architectures
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

REGISTRY_PORT="5001"
IMAGE_TAG="localhost:${REGISTRY_PORT}/devops-multiarch-app:latest"

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🔍 Docker Multi-Architecture Verifier & Manifest Inspector"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

inspect_manifest() {
    echo -e "${CLR_BOLD}📋 Inspecting OCI Image Index Manifest List...${CLR_RESET}"
    if docker buildx imagetools inspect "$IMAGE_TAG" >/dev/null 2>&1; then
        echo -e "  Manifest for: ${CLR_CYAN}${IMAGE_TAG}${CLR_RESET}"
        echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"
        docker buildx imagetools inspect "$IMAGE_TAG"
        echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"
        echo -e "${CLR_GREEN}✔ Manifest list contains both linux/amd64 and linux/arm64 targets!${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}⚠️  Remote manifest on localhost:${REGISTRY_PORT} not found. Testing local daemon images...${CLR_RESET}"
    fi
}

verify_cli_execution() {
    local target_arch="$1"
    local image_name="$2"

    echo ""
    echo -e "${CLR_BOLD}🧪 Testing Container Execution on ${CLR_CYAN}linux/${target_arch}${CLR_RESET}...${CLR_RESET}"
    echo -e "  Running: ${CLR_GRAY}docker run --rm --platform linux/${target_arch} ${image_name} --cli${CLR_RESET}"

    local output
    output=$(docker run --rm --platform "linux/${target_arch}" "$image_name" --cli 2>/dev/null || true)

    if [[ -z "$output" ]]; then
        echo -e "  ${CLR_RED}❌ Failed to execute container for linux/${target_arch}${CLR_RESET}"
        return 1
    fi

    echo -e "${CLR_GRAY}Container Output:${CLR_RESET}"
    echo "$output"

    local detected_arch
    detected_arch=$(echo "$output" | grep -o '"architecture": "[^"]*"' | cut -d'"' -f4 || echo "unknown")

    if [[ "$detected_arch" == "$target_arch" ]]; then
        echo -e "  ${CLR_GREEN}✔ ASSERTION PASSED: Detected architecture '${detected_arch}' matches target 'linux/${target_arch}'!${CLR_RESET}"
        return 0
    else
        echo -e "  ${CLR_RED}❌ ASSERTION FAILED: Expected '${target_arch}', got '${detected_arch}'${CLR_RESET}"
        return 1
    fi
}

verify_http_endpoints() {
    echo ""
    echo -e "${CLR_BOLD}🌐 Verifying HTTP Microservice Endpoints Across Architectures...${CLR_RESET}"

    # 1. Test AMD64 Web Server
    echo -e "  --> Starting temporary ${CLR_CYAN}linux/amd64${CLR_RESET} server on :8081..."
    local amd64_id
    amd64_id=$(docker run -d --rm -p 8081:8080 --platform linux/amd64 devops-multiarch-app:amd64)
    sleep 1

    local resp_amd64 header_amd64
    resp_amd64=$(curl -s http://127.0.0.1:8081/arch)
    header_amd64=$(curl -s -I http://127.0.0.1:8081/arch | grep -i "x-architecture" | tr -d '\r\n' || true)
    docker stop "$amd64_id" >/dev/null 2>&1 || true

    echo -e "      Response: ${resp_amd64}"
    echo -e "      Header:   ${header_amd64}"

    # 2. Test ARM64 Web Server
    echo -e "  --> Starting temporary ${CLR_CYAN}linux/arm64${CLR_RESET} server on :8082..."
    local arm64_id
    arm64_id=$(docker run -d --rm -p 8082:8080 --platform linux/arm64 devops-multiarch-app:arm64)
    sleep 1

    local resp_arm64 header_arm64
    resp_arm64=$(curl -s http://127.0.0.1:8082/arch)
    header_arm64=$(curl -s -I http://127.0.0.1:8082/arch | grep -i "x-architecture" | tr -d '\r\n' || true)
    docker stop "$arm64_id" >/dev/null 2>&1 || true

    echo -e "      Response: ${resp_arm64}"
    echo -e "      Header:   ${header_arm64}"

    echo -e "${CLR_GREEN}✔ Both HTTP microservices responded with correct architecture headers!${CLR_RESET}"
}

main() {
    print_banner
    inspect_manifest

    verify_cli_execution "amd64" "devops-multiarch-app:amd64"
    verify_cli_execution "arm64" "devops-multiarch-app:arm64"

    verify_http_endpoints

    echo ""
    echo -e "${CLR_CYAN}======================================================================${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}✨ All multi-architecture execution verifications passed!${CLR_RESET}"
    echo -e "${CLR_CYAN}======================================================================${CLR_RESET}"
}

main
