#!/usr/bin/env bash
# ==============================================================================
# test_rootless.sh - Automated Verification Suite for Rootless Containers
# ==============================================================================
# Validates:
#   1. Docker & user namespace environment prerequisites
#   2. Building of the Rootless Execution Lab image
#   3. User namespace UID and GID mapping (Inside UID 0 -> Host UID 1000)
#   4. Process table and PID namespace segregation
#   5. Host root file read & write exploit mitigation
#   6. Kernel sysctl and raw block device creation restrictions
#   7. Automated teardown and environment sanitation
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
IMAGE_NAME="devops-rootless-lab:latest"
CONTAINER_NAME="devops-rootless-test"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

FLAG_KEEP=false
FLAG_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./test_rootless.sh [OPTIONS]

Automated test suite verifying Rootless Container user namespaces and security boundaries.

Options:
  --keep      Leave test containers and images intact after tests complete
  --clean     Stop all containers, remove networks and built images
  -h, --help  Display this help menu

Examples:
  ./test_rootless.sh          # Run full test suite with automatic teardown
  ./test_rootless.sh --keep   # Run tests and preserve container image for manual exploration
  ./test_rootless.sh --clean  # Remove all containers and images
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
    echo -e "${CLR_YELLOW}🧹 Cleaning up all project containers and images...${CLR_RESET}"
    cd "$SCRIPT_DIR"
    docker compose down -v --remove-orphans 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" devops-rootless-lab devops-rootless-verifier 2>/dev/null || true
    docker rmi -f "$IMAGE_NAME" 2>/dev/null || true
    echo -e "${CLR_GREEN}✨ All project resources removed successfully.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == "true" ]]; then
    cleanup_resources
    exit 0
fi

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Rootless Container Execution & Isolation Test Suite"
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
    # Test 1: Docker Environment Availability
    # --------------------------------------------------------------------------
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        record_result "01" "Docker Engine Availability" 0 "Docker daemon operational"
    else
        record_result "01" "Docker Engine Availability" 1 "Docker daemon not reachable"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 2: Build Rootless Lab Container Image
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Building rootless lab container image...${CLR_RESET}"
    if docker build -t "$IMAGE_NAME" . >/dev/null 2>&1; then
        record_result "02" "Rootless Lab Image Build" 0 "Built ${IMAGE_NAME} successfully"
    else
        record_result "02" "Rootless Lab Image Build" 1 "Failed to build container image"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 3: Subordinate ID Setup & Configuration
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Testing environment configuration with setup_rootless.sh...${CLR_RESET}"
    local setup_out
    setup_out=$(docker run --rm --cap-add=SYS_ADMIN --security-opt seccomp=unconfined "$IMAGE_NAME" /home/developer/setup_rootless.sh --run 2>/dev/null || echo "")

    if echo "$setup_out" | grep -q "Inside Identity: root" && echo "$setup_out" | grep -q "1000"; then
        record_result "03" "Subordinate ID & Namespace Initialization" 0 "Verified user namespace creation and identity translation"
    else
        record_result "03" "Subordinate ID & Namespace Initialization" 1 "Unexpected setup output: ${setup_out}"
    fi

    # --------------------------------------------------------------------------
    # Test 4: Comprehensive Security Isolation Audit (verify_isolation.sh)
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Running in-depth security isolation audit suite...${CLR_RESET}"
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    if docker run --name "$CONTAINER_NAME" --cap-add=SYS_ADMIN --security-opt seccomp=unconfined "$IMAGE_NAME" /home/developer/verify_isolation.sh >/dev/null 2>&1; then
        record_result "04" "Security Isolation & Privilege Boundary Audit" 0 "All 8 user namespace isolation checks passed"
    else
        record_result "04" "Security Isolation & Privilege Boundary Audit" 1 "Security audit reported failures"
    fi
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    # --------------------------------------------------------------------------
    # Test 5: Docker Compose Integration
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Validating stack execution via Docker Compose...${CLR_RESET}"
    if docker compose run --rm rootless-verifier >/dev/null 2>&1; then
        record_result "05" "Docker Compose Stack Execution" 0 "rootless-verifier service executed and exited cleanly"
    else
        record_result "05" "Docker Compose Stack Execution" 1 "Compose service execution failed"
    fi

    # --------------------------------------------------------------------------
    # Summary & Teardown
    # --------------------------------------------------------------------------
    echo ""
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}  📊 Test Suite Summary: ${PASSED_TESTS}/${TOTAL_TESTS} Tests Passed${CLR_RESET}"
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

    if [[ "$FLAG_KEEP" == "false" ]]; then
        cleanup_resources
    else
        echo -e "${CLR_YELLOW}ℹ️  Container image preserved for manual exploration as requested (--keep).${CLR_RESET}"
    fi

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✨ All Rootless Container Environment tests passed successfully!${CLR_RESET}"
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ Some tests failed. Check the logs above.${CLR_RESET}"
        exit 1
    fi
}

run_suite
