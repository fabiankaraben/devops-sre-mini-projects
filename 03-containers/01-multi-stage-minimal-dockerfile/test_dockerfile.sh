#!/usr/bin/env bash
# ==============================================================================
# test_dockerfile.sh - Automated Verification Suite for Multi-Stage Build Project
# ==============================================================================
# Validates:
#   1. Docker environment prerequisites
#   2. Successful compilation & build of baseline and optimized images
#   3. Size threshold validation (< 25MB for slim image)
#   4. Optimization efficiency (> 90% size reduction)
#   5. Layer count optimization
#   6. Non-root user execution (UID 10001) in slim image
#   7. Privileged root execution (UID 0) in baseline fat image
#   8. Runtime functional parity (HTTP 200 on /health)
#   9. Security context endpoint validation (HTTP 200 on /info with UID 10001)
#  10. Attack surface reduction (elimination of apt/gcc/go SDK)
#  11. Build context efficiency (.dockerignore exclusion validation)
#  12. Complete resource teardown and cleanup
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

# Project Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG_FAT="mini-proj-03-01-test:fat"
TAG_SLIM="mini-proj-03-01-test:slim"
PORT_FAT=19081
PORT_SLIM=19082

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Multi-Stage Minimal Dockerfile Automated Test Suite"
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

cleanup() {
    # Stop and remove any test containers and images
    docker rm -f test-fat-runner test-slim-runner >/dev/null 2>&1 || true
    docker rmi -f "$TAG_FAT" "$TAG_SLIM" >/dev/null 2>&1 || true
}

# Trap unexpected exit and ensure cleanup
trap cleanup EXIT

main() {
    print_banner

    # Test 1: Check Docker Daemon
    echo -e "${CLR_YELLOW}Phase 1: Environment & Build Validation${CLR_RESET}"
    if docker info >/dev/null 2>&1; then
        record_result "01" "Docker daemon is active and responsive" 0 "Docker CLI & engine operational"
    else
        record_result "01" "Docker daemon is active and responsive" 1 "Docker daemon not running"
        exit 1
    fi

    # Test 2: Build Baseline Fat Image
    if DOCKER_BUILDKIT=1 docker build -q -f "${SCRIPT_DIR}/Dockerfile.fat" -t "$TAG_FAT" "$SCRIPT_DIR" >/dev/null 2>&1; then
        local fat_size
        fat_size=$(docker image inspect "$TAG_FAT" --format='{{.Size}}')
        record_result "02" "Baseline fat image builds successfully" 0 "Image: ${TAG_FAT} (${fat_size} bytes)"
    else
        record_result "02" "Baseline fat image builds successfully" 1 "Build failed for Dockerfile.fat"
    fi

    # Test 3: Build Optimized Slim Image
    if DOCKER_BUILDKIT=1 docker build -q -f "${SCRIPT_DIR}/Dockerfile.slim" -t "$TAG_SLIM" "$SCRIPT_DIR" >/dev/null 2>&1; then
        local slim_size
        slim_size=$(docker image inspect "$TAG_SLIM" --format='{{.Size}}')
        record_result "03" "Optimized multi-stage slim image builds successfully" 0 "Image: ${TAG_SLIM} (${slim_size} bytes)"
    else
        record_result "03" "Optimized multi-stage slim image builds successfully" 1 "Build failed for Dockerfile.slim"
    fi

    echo -e "\n${CLR_YELLOW}Phase 2: Image Footprint & Layer Optimization${CLR_RESET}"

    # Test 4: Image size < 25MB threshold (26,214,400 bytes)
    local slim_bytes threshold_bytes=26214400
    slim_bytes=$(docker image inspect "$TAG_SLIM" --format='{{.Size}}' 2>/dev/null || echo 0)
    local slim_mb
    slim_mb=$(awk -v b="$slim_bytes" 'BEGIN { printf "%.2f MB", b / 1048576 }')

    if [[ "$slim_bytes" -gt 0 && "$slim_bytes" -lt "$threshold_bytes" ]]; then
        record_result "04" "Slim image is strictly under 25MB threshold" 0 "Actual size: ${slim_mb} (< 25MB)"
    else
        record_result "04" "Slim image is strictly under 25MB threshold" 1 "Actual size: ${slim_mb} exceeds 25MB limit"
    fi

    # Test 5: Size reduction percentage >= 90%
    local fat_bytes pct_reduction
    fat_bytes=$(docker image inspect "$TAG_FAT" --format='{{.Size}}' 2>/dev/null || echo 1)
    pct_reduction=$(awk -v f="$fat_bytes" -v s="$slim_bytes" 'BEGIN { printf "%.2f", ((f - s) / f) * 100 }')
    local is_large_reduction
    is_large_reduction=$(awk -v p="$pct_reduction" 'BEGIN { print (p >= 90.0 ? 1 : 0) }')

    if [[ "$is_large_reduction" -eq 1 ]]; then
        record_result "05" "Image size reduction exceeds 90%" 0 "Achieved ${pct_reduction}% reduction"
    else
        record_result "05" "Image size reduction exceeds 90%" 1 "Achieved only ${pct_reduction}% reduction"
    fi

    # Test 6: Layer count comparison
    local fat_layers slim_layers
    fat_layers=$(docker history -q "$TAG_FAT" 2>/dev/null | wc -l | tr -d ' ')
    slim_layers=$(docker history -q "$TAG_SLIM" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$slim_layers" -lt "$fat_layers" ]]; then
        record_result "06" "Slim image has fewer layers than baseline fat image" 0 "Slim: ${slim_layers} layers vs Fat: ${fat_layers} layers"
    else
        record_result "06" "Slim image has fewer layers than baseline fat image" 1 "Slim: ${slim_layers} layers vs Fat: ${fat_layers} layers"
    fi

    echo -e "\n${CLR_YELLOW}Phase 3: Security Posture & Least Privilege${CLR_RESET}"

    # Test 7: Fat image runs as root (UID 0)
    local fat_user
    fat_user=$(docker inspect --format='{{.Config.User}}' "$TAG_FAT" 2>/dev/null || echo "")
    if [[ -z "$fat_user" || "$fat_user" == "root" || "$fat_user" == "0" ]]; then
        record_result "07" "Baseline fat image defaults to privileged root (UID 0)" 0 "Config.User: '${fat_user:-root (UID 0)}'"
    else
        record_result "07" "Baseline fat image defaults to privileged root (UID 0)" 1 "Unexpected Config.User: '${fat_user}'"
    fi

    # Test 8: Slim image runs as unprivileged UID 10001
    local slim_user
    slim_user=$(docker inspect --format='{{.Config.User}}' "$TAG_SLIM" 2>/dev/null || echo "")
    if [[ "$slim_user" == "10001:10001" || "$slim_user" == "10001" || "$slim_user" == "appuser" ]]; then
        record_result "08" "Slim image is configured with unprivileged UID 10001" 0 "Config.User: '${slim_user}'"
    else
        record_result "08" "Slim image is configured with unprivileged UID 10001" 1 "Config.User '${slim_user}' is not non-root UID 10001"
    fi

    # Test 9: Elimination of build toolchains (apt, gcc, go SDK) in slim image
    local temp_cid contents has_dangerous_tools=0
    temp_cid=$(docker create "$TAG_SLIM" 2>/dev/null || echo "")
    if [[ -n "$temp_cid" ]]; then
        contents=$(docker export "$temp_cid" | tar -tf - 2>/dev/null || echo "")
        docker rm -f "$temp_cid" >/dev/null 2>&1 || true

        if grep -q -E '(^|/)usr/bin/apt|(^|/)usr/bin/gcc|(^|/)usr/local/go' <<< "$contents"; then
            has_dangerous_tools=1
        fi
    fi

    if [[ "$has_dangerous_tools" -eq 0 ]]; then
        record_result "09" "Build toolchains (apt, gcc, go SDK) eliminated in slim image" 0 "Zero compiler or Debian package manager binaries in runtime"
    else
        record_result "09" "Build toolchains (apt, gcc, go SDK) eliminated in slim image" 1 "Build tools leaked into runtime image"
    fi

    echo -e "\n${CLR_YELLOW}Phase 4: Runtime Functional Parity & Health Probes${CLR_RESET}"

    # Start both containers
    docker run -d --name test-fat-runner -p "${PORT_FAT}:8080" "$TAG_FAT" >/dev/null 2>&1
    docker run -d --name test-slim-runner -p "${PORT_SLIM}:8080" "$TAG_SLIM" >/dev/null 2>&1
    sleep 2

    # Test 10: Baseline fat container responds on /health
    local fat_http_code
    fat_http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT_FAT}/health" 2>/dev/null || echo "000")
    if [[ "$fat_http_code" == "200" ]]; then
        record_result "10" "Baseline fat container responds with HTTP 200 on /health" 0 "Endpoint returned HTTP ${fat_http_code}"
    else
        record_result "10" "Baseline fat container responds with HTTP 200 on /health" 1 "Endpoint returned HTTP ${fat_http_code}"
    fi

    # Test 11: Slim container responds on /health
    local slim_http_code
    slim_http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT_SLIM}/health" 2>/dev/null || echo "000")
    if [[ "$slim_http_code" == "200" ]]; then
        record_result "11" "Optimized slim container responds with HTTP 200 on /health" 0 "Endpoint returned HTTP ${slim_http_code}"
    else
        record_result "11" "Optimized slim container responds with HTTP 200 on /health" 1 "Endpoint returned HTTP ${slim_http_code}"
    fi

    # Test 12: Slim container reports UID 10001 and is_root: false on /info
    local info_json
    info_json=$(curl -s "http://127.0.0.1:${PORT_SLIM}/info" 2>/dev/null || echo "{}")
    if grep -q '"is_root":false' <<< "$info_json" && grep -q '"uid":10001' <<< "$info_json"; then
        record_result "12" "Runtime security API asserts unprivileged UID 10001 (is_root: false)" 0 "Payload verified non-root security context"
    else
        record_result "12" "Runtime security API asserts unprivileged UID 10001 (is_root: false)" 1 "Security API did not report UID 10001: ${info_json}"
    fi

    # Stop test containers
    docker rm -f test-fat-runner test-slim-runner >/dev/null 2>&1 || true

    echo -e "\n${CLR_YELLOW}Phase 5: Build Context & Cleanup Verification${CLR_RESET}"

    # Test 13: .dockerignore exclusion of docs and scripts
    if [[ -f "${SCRIPT_DIR}/.dockerignore" ]] && grep -q '\*\.md' "${SCRIPT_DIR}/.dockerignore" && grep -q '\*\.sh' "${SCRIPT_DIR}/.dockerignore"; then
        record_result "13" ".dockerignore correctly filters documentation and shell scripts" 0 "Build context optimized"
    else
        record_result "13" ".dockerignore correctly filters documentation and shell scripts" 1 "Missing recommended ignore rules"
    fi

    # Test 14: Automated cleanup validation
    docker rmi -f "$TAG_FAT" "$TAG_SLIM" >/dev/null 2>&1 || true
    if ! docker image inspect "$TAG_FAT" >/dev/null 2>&1 && ! docker image inspect "$TAG_SLIM" >/dev/null 2>&1; then
        record_result "14" "Full resource cleanup validation" 0 "All temporary test images and containers removed"
    else
        record_result "14" "Full resource cleanup validation" 1 "Failed to remove test images"
    fi

    # Summary
    echo ""
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"
    echo -e "  Test Results: ${CLR_GREEN}${PASSED_TESTS} Passed${CLR_RESET}, ${CLR_RED}${FAILED_TESTS} Failed${CLR_RESET} (Total: ${TOTAL_TESTS})"
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✔ ALL TESTS PASSED SUCCESSFULLY!${CLR_RESET}\n"
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}✘ SOME TESTS FAILED!${CLR_RESET}\n"
        exit 1
    fi
}

main
