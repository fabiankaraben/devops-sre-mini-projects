#!/usr/bin/env bash
# ==============================================================================
# test_autoheal.sh - Automated Verification Suite for Autoheal & Healthchecks
# ==============================================================================
# Validates:
#   1. Docker & Docker Compose environment availability
#   2. Orchestration of Flaky App and Autoheal Daemon
#   3. Initial healthy state convergence
#   4. HTTP probe endpoint validation (HTTP 200 on /health)
#   5. Failure injection via POST /break
#   6. Docker transition to UNHEALTHY state
#   7. Autoheal event detection and graceful restart trigger
#   8. Automatic recovery back to HEALTHY state
#   9. Full teardown and resource cleanup
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

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_APP="${PORT_APP:-8091}"
BASE_URL="http://127.0.0.1:${PORT_APP}"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

FLAG_KEEP=false
FLAG_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./test_autoheal.sh [OPTIONS]

Automated test suite verifying Docker healthchecks and automated self-healing.

Options:
  --keep      Leave the stack running after tests complete
  --clean     Stop all containers, remove networks and built images
  -h, --help  Display this help menu

Examples:
  ./test_autoheal.sh          # Run full test suite with automatic teardown
  ./test_autoheal.sh --keep   # Run tests and keep stack running for manual tests
  ./test_autoheal.sh --clean  # Clean up all created resources
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

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Container Healthchecks & Autoheal Automated Test Suite"
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
    echo -e "${CLR_CYAN}🧹 Tearing down Docker Compose autoheal stack...${CLR_RESET}"
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down -v --rmi local >/dev/null 2>&1 || true
    echo -e "${CLR_GREEN}✔ Teardown complete. Zero leftover resources.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == true ]]; then
    print_banner
    do_cleanup
    exit 0
fi

main() {
    print_banner

    # Phase 1: Environment & Launch
    echo -e "${CLR_YELLOW}Phase 1: Environment & Orchestration Launch${CLR_RESET}"

    # Test 1: Check Docker
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        record_result "01" "Docker & Docker Compose CLI operational" 0 "Engine active"
    else
        record_result "01" "Docker & Docker Compose CLI operational" 1 "Docker not found"
        exit 1
    fi

    # Test 2: Build & Start Stack
    echo -e "  ${CLR_GRAY}Starting stack with 'docker compose up -d --build'...${CLR_RESET}"
    local build_output
    if build_output=$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build 2>&1); then
        record_result "02" "Flaky app and Autoheal daemon launched" 0 "Containers started"
    else
        record_result "02" "Flaky app and Autoheal daemon launched" 1 "Launch failed: ${build_output}"
        exit 1
    fi

    # Test 3: Wait for initial healthy status
    echo -e "  ${CLR_GRAY}Awaiting initial healthy status...${CLR_RESET}"
    local max_wait=20
    local elapsed=0
    local initial_healthy=false

    while [[ "$elapsed" -lt "$max_wait" ]]; do
        local ps_out
        ps_out=$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps 2>/dev/null || true)
        if grep -q "autoheal-flaky-service" <<< "$ps_out" && grep -q "(healthy)" <<< "$ps_out"; then
            initial_healthy=true
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ "$initial_healthy" == true ]]; then
        record_result "03" "Target container reaches initial HEALTHY state" 0 "Probed healthy in ${elapsed}s"
    else
        record_result "03" "Target container reaches initial HEALTHY state" 1 "Timed out waiting for healthy status"
    fi

    # Phase 2: Baseline Health & Probes
    echo -e "\n${CLR_YELLOW}Phase 2: Baseline Health Probe Validation${CLR_RESET}"

    # Test 4: Root endpoint responds
    local root_json
    root_json=$(curl -s "${BASE_URL}/" 2>/dev/null || echo "{}")
    if grep -q '"is_healthy": true' <<< "$root_json"; then
        record_result "04" "Root endpoint confirms service is operational" 0 "HTTP 200 from ${BASE_URL}/"
    else
        record_result "04" "Root endpoint confirms service is operational" 1 "Invalid response: ${root_json}"
    fi

    # Test 5: Health probe returns HTTP 200
    local health_code
    health_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
    if [[ "$health_code" == "200" ]]; then
        record_result "05" "Healthcheck probe returns HTTP 200 OK" 0 "GET /health responding UP"
    else
        record_result "05" "Healthcheck probe returns HTTP 200 OK" 1 "Returned HTTP ${health_code}"
    fi

    # Phase 3: Chaos Injection & Unhealthy Assertion
    echo -e "\n${CLR_YELLOW}Phase 3: Chaos Injection & Unhealthy State Detection${CLR_RESET}"

    # Record container initial start time/ID
    local initial_cid initial_start_time
    initial_cid=$(docker inspect --format='{{.Id}}' autoheal-flaky-service 2>/dev/null || echo "")
    initial_start_time=$(docker inspect --format='{{.State.StartedAt}}' autoheal-flaky-service 2>/dev/null || echo "")

    # Test 6: Trigger chaos via POST /break
    local break_res
    break_res=$(curl -s -X POST "${BASE_URL}/break" 2>/dev/null || echo "{}")
    if grep -q '"state": "UNHEALTHY"' <<< "$break_res"; then
        record_result "06" "Chaos injected via POST /break" 0 "Simulated failure active"
    else
        record_result "06" "Chaos injected via POST /break" 1 "Break trigger failed: ${break_res}"
    fi

    # Test 7: Verify /health returns HTTP 503
    local broken_code
    broken_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
    if [[ "$broken_code" == "503" ]]; then
        record_result "07" "Health probe immediately fails with HTTP 503" 0 "GET /health returned HTTP 503"
    else
        record_result "07" "Health probe immediately fails with HTTP 503" 1 "Expected HTTP 503, got ${broken_code}"
    fi

    # Test 8: Await Docker marking container as UNHEALTHY
    echo -e "  ${CLR_GRAY}Waiting for Docker to mark container as UNHEALTHY (retries=2)...${CLR_RESET}"
    local max_unhealthy_wait=20
    local u_elapsed=0
    local became_unhealthy=false

    while [[ "$u_elapsed" -lt "$max_unhealthy_wait" ]]; do
        local health_status
        health_status=$(docker inspect --format='{{.State.Health.Status}}' autoheal-flaky-service 2>/dev/null || echo "unknown")
        if [[ "$health_status" == "unhealthy" ]]; then
            became_unhealthy=true
            break
        fi
        sleep 1
        u_elapsed=$((u_elapsed + 1))
    done

    if [[ "$became_unhealthy" == true ]]; then
        record_result "08" "Docker Engine marks container status as UNHEALTHY" 0 "Failed probes detected in ${u_elapsed}s"
    else
        record_result "08" "Docker Engine marks container status as UNHEALTHY" 1 "Container did not transition to unhealthy"
    fi

    # Phase 4: Auto-Healing & Recovery
    echo -e "\n${CLR_YELLOW}Phase 4: Automated Self-Healing & Recovery Validation${CLR_RESET}"

    # Test 9: Wait for Autoheal Daemon to trigger restart and recover
    echo -e "  ${CLR_GRAY}Waiting for Autoheal Daemon to restart and recover container...${CLR_RESET}"
    local max_recovery_wait=30
    local r_elapsed=0
    local recovered_healthy=false

    while [[ "$r_elapsed" -lt "$max_recovery_wait" ]]; do
        local new_start_time current_health
        new_start_time=$(docker inspect --format='{{.State.StartedAt}}' autoheal-flaky-service 2>/dev/null || echo "")
        current_health=$(docker inspect --format='{{.State.Health.Status}}' autoheal-flaky-service 2>/dev/null || echo "")

        if [[ "$new_start_time" != "$initial_start_time" && "$current_health" == "healthy" ]]; then
            recovered_healthy=true
            break
        fi
        sleep 2
        r_elapsed=$((r_elapsed + 2))
    done

    if [[ "$recovered_healthy" == true ]]; then
        record_result "09" "Autoheal daemon triggered restart and recovered container" 0 "Container recovered to HEALTHY in ${r_elapsed}s"
    else
        record_result "09" "Autoheal daemon triggered restart and recovered container" 1 "Recovery timed out"
    fi

    # Test 10: Verify /health returns HTTP 200 again
    local recovered_code
    recovered_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
    if [[ "$recovered_code" == "200" ]]; then
        record_result "10" "Recovered container responds with HTTP 200 on /health" 0 "Service state restored"
    else
        record_result "10" "Recovered container responds with HTTP 200 on /health" 1 "Returned HTTP ${recovered_code}"
    fi

    # Summary
    echo ""
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"
    echo -e "  Test Results: ${CLR_GREEN}${PASSED_TESTS} Passed${CLR_RESET}, ${CLR_RED}${FAILED_TESTS} Failed${CLR_RESET} (Total: ${TOTAL_TESTS})"
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✔ ALL HEALTHCHECK & AUTOHEAL TESTS PASSED!${CLR_RESET}\n"
    else
        echo -e "${CLR_RED}${CLR_BOLD}✘ SOME TESTS FAILED!${CLR_RESET}\n"
    fi

    if [[ "$FLAG_KEEP" == true ]]; then
        echo -e "${CLR_YELLOW}ℹ Stack left running (--keep specified).${CLR_RESET}"
        echo -e "  • Flaky App Endpoint: ${CLR_BOLD}${BASE_URL}${CLR_RESET}"
        echo -e "  • Inject Failure:     ${CLR_BOLD}curl -X POST ${BASE_URL}/break${CLR_RESET}"
        echo -e "  To stop and clean up later, run: ${CLR_CYAN}./test_autoheal.sh --clean${CLR_RESET}\n"
    else
        do_cleanup
    fi

    if [[ "$FAILED_TESTS" -gt 0 ]]; then
        exit 1
    fi
}

main
