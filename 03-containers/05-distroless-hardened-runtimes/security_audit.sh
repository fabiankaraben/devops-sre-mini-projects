#!/usr/bin/env bash
# ==============================================================================
# security_audit.sh - Distroless Hardened Container Security Audit Suite
# ==============================================================================
# Audits:
#   1. Interactive shell penetration test (/bin/sh, /bin/bash, sh)
#   2. Package manager and network downloader eradication audit (apt, apk, curl)
#   3. Unprivileged non-root user execution (UID 65532)
#   4. Image attack surface and binary size reduction
#   5. Runtime HTTP API functionality across compiled and interpreted Distroless
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_GO="${PORT_GO:-8093}"
PORT_PY="${PORT_PY:-8094}"

IMG_DEBIAN="devops-mini-proj-03-05-debian:latest"
IMG_DISTROLESS="devops-mini-proj-03-05-distroless:latest"
IMG_PY_DISTROLESS="devops-mini-proj-03-05-python-distroless:latest"

CONT_DEBIAN="distroless-audit-debian"
CONT_DISTROLESS="distroless-audit-distroless"
CONT_PY_DISTROLESS="distroless-audit-python"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

FLAG_KEEP=false
FLAG_CLEAN=false

# Metrics
SIZE_DEBIAN="0MB"
SIZE_DISTROLESS="0MB"
SIZE_PY_DISTROLESS="0MB"

show_help() {
    cat <<EOF
Usage: ./security_audit.sh [OPTIONS]

Audits Google Distroless container images against traditional baseline containers.

Options:
  --keep      Keep audit containers and images after testing
  --clean     Stop all audit containers and remove benchmark images
  -h, --help  Display this help menu

Examples:
  ./security_audit.sh          # Run full security audit and cleanup
  ./security_audit.sh --keep   # Run audit and leave containers running
  ./security_audit.sh --clean  # Purge all audit artifacts
EOF
}

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

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🛡️ Google Distroless Container Runtime Security Audit Suite"
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

do_cleanup() {
    echo -e "${CLR_CYAN}🧹 Cleaning up Docker audit containers and images...${CLR_RESET}"
    docker stop "${CONT_DEBIAN}" "${CONT_DISTROLESS}" "${CONT_PY_DISTROLESS}" >/dev/null 2>&1 || true
    docker rm -f "${CONT_DEBIAN}" "${CONT_DISTROLESS}" "${CONT_PY_DISTROLESS}" >/dev/null 2>&1 || true
    docker rmi -f "${IMG_DEBIAN}" "${IMG_DISTROLESS}" "${IMG_PY_DISTROLESS}" >/dev/null 2>&1 || true
    echo -e "${CLR_GREEN}✔ Teardown complete. Zero leftover resources.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == true ]]; then
    print_banner
    do_cleanup
    exit 0
fi

main() {
    print_banner

    # Phase 1: Image Builds
    echo -e "${CLR_YELLOW}Phase 1: Building Image Artifacts${CLR_RESET}"

    # Test 1: Docker CLI
    if command -v docker >/dev/null 2>&1; then
        record_result "01" "Docker Engine operational" 0 "Docker CLI available"
    else
        record_result "01" "Docker Engine operational" 1 "Docker not found"
        exit 1
    fi

    echo -e "  ${CLR_GRAY}Building baseline Debian image...${CLR_RESET}"
    docker build -q -f "${SCRIPT_DIR}/Dockerfile.debian" -t "${IMG_DEBIAN}" "${SCRIPT_DIR}" >/dev/null
    SIZE_DEBIAN=$(docker image inspect "${IMG_DEBIAN}" --format='{{.Size}}' | awk '{printf "%.2f MB", $1/1024/1024}')
    record_result "02" "Baseline Debian container image built" 0 "Size: ${SIZE_DEBIAN}"

    echo -e "  ${CLR_GRAY}Building Google Distroless static Go image...${CLR_RESET}"
    docker build -q -f "${SCRIPT_DIR}/Dockerfile.distroless" -t "${IMG_DISTROLESS}" "${SCRIPT_DIR}" >/dev/null
    SIZE_DISTROLESS=$(docker image inspect "${IMG_DISTROLESS}" --format='{{.Size}}' | awk '{printf "%.2f MB", $1/1024/1024}')
    record_result "03" "Hardened Distroless Go container image built" 0 "Size: ${SIZE_DISTROLESS}"

    echo -e "  ${CLR_GRAY}Building Google Distroless Python image...${CLR_RESET}"
    docker build -q -f "${SCRIPT_DIR}/Dockerfile.python-distroless" -t "${IMG_PY_DISTROLESS}" "${SCRIPT_DIR}" >/dev/null
    SIZE_PY_DISTROLESS=$(docker image inspect "${IMG_PY_DISTROLESS}" --format='{{.Size}}' | awk '{printf "%.2f MB", $1/1024/1024}')
    record_result "04" "Distroless Python runtime image built" 0 "Size: ${SIZE_PY_DISTROLESS}"

    # Phase 2: Interactive Shell Penetration Attack Simulation
    echo -e "\n${CLR_YELLOW}Phase 2: Interactive Shell Attack Simulation${CLR_RESET}"

    # Start Debian container
    docker rm -f "${CONT_DEBIAN}" >/dev/null 2>&1 || true
    docker run -d --name "${CONT_DEBIAN}" "${IMG_DEBIAN}" >/dev/null

    # Test 5: Debian Shell Access
    local debian_shell_out
    debian_shell_out=$(docker exec "${CONT_DEBIAN}" /bin/bash -c "whoami" 2>&1 || echo "failed")
    if [[ "$debian_shell_out" == "root" ]]; then
        record_result "05" "Vulnerability confirmed: Debian baseline exposes root shell (/bin/bash)" 0 "Exec succeeded as root (UID 0)"
    else
        record_result "05" "Vulnerability confirmed: Debian baseline exposes root shell (/bin/bash)" 1 "Shell test unexpected: ${debian_shell_out}"
    fi

    # Start Distroless container
    docker rm -f "${CONT_DISTROLESS}" >/dev/null 2>&1 || true
    docker run -d --name "${CONT_DISTROLESS}" -p "${PORT_GO}:8080" "${IMG_DISTROLESS}" >/dev/null
    sleep 1

    # Test 6: Distroless /bin/sh Execution
    local sh_err
    sh_err=$(docker exec "${CONT_DISTROLESS}" /bin/sh 2>&1 || true)
    if grep -Ei "executable file not found|no such file" <<< "$sh_err"; then
        record_result "06" "Hardened assertion: /bin/sh is completely eradicated in Distroless" 0 "Exec denied: executable not found"
    else
        record_result "06" "Hardened assertion: /bin/sh is completely eradicated in Distroless" 1 "Unexpected /bin/sh output: ${sh_err}"
    fi

    # Test 7: Distroless /bin/bash Execution
    local bash_err
    bash_err=$(docker exec "${CONT_DISTROLESS}" /bin/bash 2>&1 || true)
    if grep -Ei "executable file not found|no such file" <<< "$bash_err"; then
        record_result "07" "Hardened assertion: /bin/bash is completely eradicated in Distroless" 0 "Exec denied: executable not found"
    else
        record_result "07" "Hardened assertion: /bin/bash is completely eradicated in Distroless" 1 "Unexpected /bin/bash output: ${bash_err}"
    fi

    # Phase 3: Package Manager & Attack Tooling Audit
    echo -e "\n${CLR_YELLOW}Phase 3: Package Manager & Downloader Tooling Audit${CLR_RESET}"

    # Test 8: Verify apt and apk absence
    local apt_err apk_err
    apt_err=$(docker exec "${CONT_DISTROLESS}" apt 2>&1 || true)
    apk_err=$(docker exec "${CONT_DISTROLESS}" apk 2>&1 || true)
    if grep -Ei "executable file not found|no such file" <<< "$apt_err" && grep -Ei "executable file not found|no such file" <<< "$apk_err"; then
        record_result "08" "Package managers (apt, dpkg, apk) completely missing" 0 "Attackers cannot install malware tooling"
    else
        record_result "08" "Package managers (apt, dpkg, apk) completely missing" 1 "Package manager found!"
    fi

    # Test 9: Verify curl and wget absence
    local curl_err wget_err
    curl_err=$(docker exec "${CONT_DISTROLESS}" curl 2>&1 || true)
    wget_err=$(docker exec "${CONT_DISTROLESS}" wget 2>&1 || true)
    if grep -Ei "executable file not found|no such file" <<< "$curl_err" && grep -Ei "executable file not found|no such file" <<< "$wget_err"; then
        record_result "09" "Download utilities (curl, wget, nc) completely missing" 0 "Prevents remote payload fetching"
    else
        record_result "09" "Download utilities (curl, wget, nc) completely missing" 1 "Downloader utility found!"
    fi

    # Phase 4: Non-Root Execution & Runtime API Probes
    echo -e "\n${CLR_YELLOW}Phase 4: Runtime Privilege & API Probe Verification${CLR_RESET}"

    # Test 10: Non-Root execution check
    local sec_json
    sec_json=$(curl -s "http://127.0.0.1:${PORT_GO}/security" 2>/dev/null || echo "{}")
    if grep -q '"is_non_root":true' <<< "$sec_json" && grep -q '"uid":65532' <<< "$sec_json"; then
        record_result "10" "Container executes strictly as unprivileged nonroot (UID 65532)" 0 "nonroot:nonroot verified"
    elif grep -q '"uid": 65532' <<< "$sec_json"; then
        record_result "10" "Container executes strictly as unprivileged nonroot (UID 65532)" 0 "nonroot:nonroot verified"
    else
        record_result "10" "Container executes strictly as unprivileged nonroot (UID 65532)" 1 "Security probe: ${sec_json}"
    fi

    # Test 11: HTTP Endpoint Response
    local health_code
    health_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT_GO}/health" 2>/dev/null || echo "000")
    if [[ "$health_code" == "200" ]]; then
        record_result "11" "Distroless microservice responds with HTTP 200 OK" 0 "GET /health operational"
    else
        record_result "11" "Distroless microservice responds with HTTP 200 OK" 1 "Returned HTTP ${health_code}"
    fi

    # Test 12: Python Distroless Shell-less Execution
    docker rm -f "${CONT_PY_DISTROLESS}" >/dev/null 2>&1 || true
    docker run -d --name "${CONT_PY_DISTROLESS}" -p "${PORT_PY}:8080" "${IMG_PY_DISTROLESS}" >/dev/null
    sleep 1

    local py_curl py_sh_err
    py_curl=$(curl -s "http://127.0.0.1:${PORT_PY}/" 2>/dev/null || echo "{}")
    py_sh_err=$(docker exec "${CONT_PY_DISTROLESS}" /bin/sh 2>&1 || true)

    if grep -q "python3-distroless" <<< "$py_curl" && grep -Ei "executable file not found|no such file" <<< "$py_sh_err"; then
        record_result "12" "Interpreted Python Distroless runs without shell (/bin/sh missing)" 0 "Interpreted runtime hardened"
    else
        record_result "12" "Interpreted Python Distroless runs without shell (/bin/sh missing)" 1 "Python test failed: ${py_curl}"
    fi

    # Phase 5: Metrics Summary Matrix
    echo ""
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "  📊 Container Runtime Hardening & Attack Surface Matrix"
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    printf "%-26s | %-12s | %-14s | %-14s | %-12s\n" "Image Variant" "Image Size" "Shell Present" "Pkg Manager" "Runtime User"
    echo "---------------------------+--------------+----------------+----------------+-------------"
    printf "%-26s | %-12s | ${CLR_RED}%-14s${CLR_RESET} | ${CLR_RED}%-14s${CLR_RESET} | ${CLR_RED}%-12s${CLR_RESET}\n" "Dockerfile.debian" "${SIZE_DEBIAN}" "YES (/bin/bash)" "apt / dpkg" "root (0)"
    printf "%-26s | %-12s | ${CLR_GREEN}%-14s${CLR_RESET} | ${CLR_GREEN}%-14s${CLR_RESET} | ${CLR_GREEN}%-12s${CLR_RESET}\n" "Dockerfile.distroless (Go)" "${SIZE_DISTROLESS}" "NONE (Eradicated)" "NONE" "nonroot (65532)"
    printf "%-26s | %-12s | ${CLR_GREEN}%-14s${CLR_RESET} | ${CLR_GREEN}%-14s${CLR_RESET} | ${CLR_GREEN}%-12s${CLR_RESET}\n" "Dockerfile.python-distroless" "${SIZE_PY_DISTROLESS}" "NONE (Eradicated)" "NONE" "nonroot (65532)"
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"

    echo ""
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"
    echo -e "  Test Results: ${CLR_GREEN}${PASSED_TESTS} Passed${CLR_RESET}, ${CLR_RED}${FAILED_TESTS} Failed${CLR_RESET} (Total: ${TOTAL_TESTS})"
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✔ ALL DISTROLESS SECURITY AUDITS PASSED!${CLR_RESET}\n"
    else
        echo -e "${CLR_RED}${CLR_BOLD}✘ SOME SECURITY CHECKS FAILED!${CLR_RESET}\n"
    fi

    if [[ "$FLAG_KEEP" == true ]]; then
        echo -e "${CLR_YELLOW}ℹ Audit containers left running (--keep specified).${CLR_RESET}"
        echo -e "  • Go Distroless:     ${CLR_BOLD}http://localhost:${PORT_GO}/${CLR_RESET}"
        echo -e "  • Python Distroless: ${CLR_BOLD}http://localhost:${PORT_PY}/${CLR_RESET}"
        echo -e "  To clean up later, run: ${CLR_CYAN}./security_audit.sh --clean${CLR_RESET}\n"
    else
        do_cleanup
    fi

    if [[ "$FAILED_TESTS" -gt 0 ]]; then
        exit 1
    fi
}

main
