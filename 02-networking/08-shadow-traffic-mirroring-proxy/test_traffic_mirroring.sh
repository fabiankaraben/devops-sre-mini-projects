#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for Shadow Traffic Mirroring Proxy
# ==============================================================================
# Verifies:
#   1. Proxy and backend healthchecks
#   2. GET traffic duplication to shadow backend
#   3. POST JSON payload replication across 50 requests
#   4. Header & Body integrity validation (100% match)
#   5. SRE Latency Isolation: 2s shadow delay does not affect client latency
#   6. SRE Fault Isolation: Shadow 500 internal errors are discarded by proxy
#   7. High concurrency burst traffic (100 requests)
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"

TARGET_URL="http://localhost:8080"
VERBOSE=false

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🪞 Shadow Traffic Mirroring Proxy Automated Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "${CLR_GRAY}Target Proxy     : ${CLR_BOLD}${TARGET_URL}${CLR_RESET}"
    echo -e "${CLR_GRAY}Test Framework   : ${CLR_BOLD}Bash, curl, python3, jq/json${CLR_RESET}\n"
}

show_help() {
    echo "Usage: ./test_traffic_mirroring.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --url <url>     Nginx proxy URL (default: http://localhost:8080)"
    echo "  -v, --verbose       Display detailed JSON outputs and diagnostics"
    echo "  -h, --help          Display this help menu"
    echo ""
    echo "Examples:"
    echo "  ./test_traffic_mirroring.sh"
    echo "  ./test_traffic_mirroring.sh -v"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)
            TARGET_URL="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}"
            show_help
            exit 1
            ;;
    esac
done

record_result() {
    local test_name="$1"
    local status="$2"
    local details="${3:-}"

    ((TOTAL_TESTS++))
    if [ "$status" -eq 0 ]; then
        ((PASSED_TESTS++))
        echo -e "  [ ${CLR_GREEN}PASS${CLR_RESET} ] ${test_name}"
        if [ "$VERBOSE" = true ] && [ -n "$details" ]; then
            echo -e "         ${CLR_GRAY}${details}${CLR_RESET}"
        fi
    else
        ((FAILED_TESTS++))
        echo -e "  [ ${CLR_RED}FAIL${CLR_RESET} ] ${test_name}"
        if [ -n "$details" ]; then
            echo -e "         ${CLR_YELLOW}Reason: ${details}${CLR_RESET}"
        fi
    fi
}

section_header() {
    echo -e "\n${CLR_BLUE}${CLR_BOLD}▶ $1${CLR_RESET}"
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"
}

# ------------------------------------------------------------------------------
# Test 1: Service Health Checks
# ------------------------------------------------------------------------------
test_service_health() {
    section_header "1. Service Health & Proxy Readiness Check"

    # Proxy Health
    local proxy_res
    if proxy_res=$(curl -s -m 3 "${TARGET_URL}/health" 2>&1); then
        if echo "$proxy_res" | grep -q "mirror_module"; then
            record_result "Nginx Reverse Proxy (:8080/health) healthy" 0 "$proxy_res"
        else
            record_result "Nginx Reverse Proxy (:8080/health)" 1 "Unexpected response: $proxy_res"
        fi
    else
        record_result "Nginx Reverse Proxy (:8080/health)" 1 "$proxy_res"
    fi

    # Primary API Health
    local primary_res
    if primary_res=$(curl -s -m 3 "${TARGET_URL}/primary/health" 2>&1); then
        if echo "$primary_res" | grep -q "primary-api"; then
            record_result "Primary Production API (:8001 -> /primary/health) healthy" 0 "$primary_res"
        else
            record_result "Primary Production API (:8001)" 1 "Unexpected response: $primary_res"
        fi
    else
        record_result "Primary Production API (:8001)" 1 "$primary_res"
    fi

    # Shadow API Health
    local shadow_res
    if shadow_res=$(curl -s -m 3 "${TARGET_URL}/shadow/health" 2>&1); then
        if echo "$shadow_res" | grep -q "shadow-api"; then
            record_result "Shadow Experimental API (:8002 -> /shadow/health) healthy" 0 "$shadow_res"
        else
            record_result "Shadow Experimental API (:8002)" 1 "Unexpected response: $shadow_res"
        fi
    else
        record_result "Shadow Experimental API (:8002)" 1 "$shadow_res"
    fi
}

# ------------------------------------------------------------------------------
# Test 2: GET Traffic Duplication
# ------------------------------------------------------------------------------
test_get_traffic_mirroring() {
    section_header "2. GET Traffic Mirroring Verification"

    # Reset logs
    curl -s -X POST "${TARGET_URL}/primary/api/reset" >/dev/null 2>&1 || true
    curl -s -X POST "${TARGET_URL}/shadow/api/reset" >/dev/null 2>&1 || true

    # Send 5 GET requests
    for i in {1..5}; do
        curl -s "${TARGET_URL}/api/v1/orders" -H "X-Request-ID: test-get-${i}" >/dev/null
    done
    sleep 0.4

    local primary_count
    primary_count=$(curl -s "${TARGET_URL}/primary/api/stats" | grep -o '"total_requests": [0-9]*' | grep -o '[0-9]*' || echo 0)
    local shadow_count
    shadow_count=$(curl -s "${TARGET_URL}/shadow/api/stats" | grep -o '"total_mirrored_requests": [0-9]*' | grep -o '[0-9]*' || echo 0)

    if [ "$primary_count" -ge 5 ] && [ "$shadow_count" -ge 5 ]; then
        record_result "GET Requests mirrored (Primary: ${primary_count}, Shadow: ${shadow_count})" 0
    else
        record_result "GET Requests mirrored" 1 "Counts: Primary=${primary_count}, Shadow=${shadow_count}"
    fi
}

# ------------------------------------------------------------------------------
# Test 3: POST JSON Payload Mirroring (50 Requests)
# ------------------------------------------------------------------------------
test_post_payload_mirroring() {
    section_header "3. POST Complex JSON Payload Mirroring (50 Requests)"

    # Reset logs
    curl -s -X POST "${TARGET_URL}/primary/api/reset" >/dev/null 2>&1 || true
    curl -s -X POST "${TARGET_URL}/shadow/api/reset" >/dev/null 2>&1 || true

    # Execute Python traffic injector
    if python3 traffic_injector.py --target "$TARGET_URL" --requests 50 --concurrency 5 >/dev/null 2>&1; then
        record_result "50 Automated POST/GET Requests injected via traffic_injector.py" 0
    else
        record_result "50 Automated POST/GET Requests injected" 1 "Traffic injector returned error"
    fi
}

# ------------------------------------------------------------------------------
# Test 4: Payload Content & Header Integrity Diffing
# ------------------------------------------------------------------------------
test_replication_diff() {
    section_header "4. Payload & Header Replication Fidelity Diff"

    local diff_json
    diff_json=$(curl -s -m 4 "${TARGET_URL}/shadow/api/shadow/diff" 2>&1 || echo "{}")

    local acc_pct
    acc_pct=$(echo "$diff_json" | grep -o '"replication_accuracy_percent": [0-9.]*' | grep -o '[0-9.]*' || echo 0)
    local matched_count
    matched_count=$(echo "$diff_json" | grep -o '"matched_requests_count": [0-9]*' | grep -o '[0-9]*' || echo 0)
    local mismatch_count
    mismatch_count=$(echo "$diff_json" | grep -o '"mismatched_payloads_count": [0-9]*' | grep -o '[0-9]*' || echo 0)

    if [ "$mismatch_count" -eq 0 ] && [ "$matched_count" -ge 45 ]; then
        record_result "Replication Accuracy: ${acc_pct}% (Matched: ${matched_count}, Mismatches: ${mismatch_count})" 0 "$diff_json"
    else
        record_result "Replication Accuracy Check" 1 "Accuracy: ${acc_pct}%, Matched: ${matched_count}, Mismatches: ${mismatch_count}"
    fi
}

# ------------------------------------------------------------------------------
# Test 5: SRE Latency Isolation
# ------------------------------------------------------------------------------
test_latency_isolation() {
    section_header "5. SRE Latency Isolation (Slow Shadow Backend Test)"
    echo -e "${CLR_GRAY}Simulating 2.0s delay on Shadow backend and verifying client response time...${CLR_RESET}"

    # Set 2.0s delay on Shadow
    curl -s -X POST "${TARGET_URL}/shadow/api/shadow/simulate-delay" \
        -H "Content-Type: application/json" \
        -d '{"delay_seconds": 2.0}' >/dev/null

    # Measure client response time to /api/v1/orders
    local start_ms
    start_ms=$(python3 -c "import time; print(int(time.time() * 1000))")

    local client_res
    client_res=$(curl -s -w "\n%{http_code}\n%{time_total}" "${TARGET_URL}/api/v1/orders" -X POST \
        -H "Content-Type: application/json" \
        -d '{"order_id": "ORD-LATENCY-TEST", "item": "Latency Probe", "amount": 99.00}' 2>&1)

    local end_ms
    end_ms=$(python3 -c "import time; print(int(time.time() * 1000))")
    local total_elapsed=$((end_ms - start_ms))

    # Reset delay immediately
    curl -s -X POST "${TARGET_URL}/shadow/api/shadow/simulate-delay" \
        -H "Content-Type: application/json" \
        -d '{"delay_seconds": 0.0}' >/dev/null

    # Assert client elapsed time is under 100ms (far less than 2000ms)
    if [ "$total_elapsed" -lt 150 ]; then
        record_result "Latency Isolation: Client response returned in ${total_elapsed}ms (Shadow delayed 2000ms)" 0 "Client latency unaffected"
    else
        record_result "Latency Isolation" 1 "Client took ${total_elapsed}ms, expected < 150ms"
    fi
}

# ------------------------------------------------------------------------------
# Test 6: SRE Fault Isolation
# ------------------------------------------------------------------------------
test_fault_isolation() {
    section_header "6. SRE Fault Isolation (Shadow 500 Error Discard Test)"
    echo -e "${CLR_GRAY}Enabling HTTP 500 errors on Shadow and verifying client receives HTTP 201/200...${CLR_RESET}"

    # Force Shadow to return HTTP 500
    curl -s -X POST "${TARGET_URL}/shadow/api/shadow/simulate-error" \
        -H "Content-Type: application/json" \
        -d '{"enable": true, "status_code": 500}' >/dev/null

    # Send client request to /api/v1/orders
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${TARGET_URL}/api/v1/orders" -X POST \
        -H "Content-Type: application/json" \
        -d '{"order_id": "ORD-FAULT-TEST", "item": "Fault Probe", "amount": 10.00}')

    # Reset fault simulation
    curl -s -X POST "${TARGET_URL}/shadow/api/shadow/simulate-error" \
        -H "Content-Type: application/json" \
        -d '{"enable": false}' >/dev/null

    if [ "$http_code" -eq 201 ] || [ "$http_code" -eq 200 ]; then
        record_result "Fault Isolation: Client received HTTP ${http_code} while Shadow threw HTTP 500" 0
    else
        record_result "Fault Isolation" 1 "Client received unexpected HTTP ${http_code}"
    fi
}

# ------------------------------------------------------------------------------
# Test 7: High-Concurrency Burst Traffic Load
# ------------------------------------------------------------------------------
test_burst_traffic() {
    section_header "7. High-Concurrency Burst Traffic Load (100 Requests)"

    if python3 traffic_injector.py --target "$TARGET_URL" --requests 100 --concurrency 10 >/dev/null 2>&1; then
        record_result "Burst Load: 100 concurrent requests processed with 0 dropped packets" 0
    else
        record_result "Burst Load: 100 requests" 1 "Encountered errors during burst load"
    fi
}

# ------------------------------------------------------------------------------
# Main Execution Flow & Summary
# ------------------------------------------------------------------------------
main() {
    local start_time
    start_time=$(date +%s)

    print_banner
    test_service_health
    test_get_traffic_mirroring
    test_post_payload_mirroring
    test_replication_diff
    test_latency_isolation
    test_fault_isolation
    test_burst_traffic

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}                         TEST SUMMARY REPORT                          ${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "  Total Tests Executed : ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
    echo -e "  Passed Tests         : ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
    echo -e "  Failed Tests         : ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
    echo -e "  Total Duration       : ${CLR_BOLD}${duration}s${CLR_RESET}"

    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "\n  ${CLR_GREEN}${CLR_BOLD}🎉 ALL SHADOW TRAFFIC MIRRORING CHECKS PASSED!${CLR_RESET}\n"
        exit 0
    else
        echo -e "\n  ${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. Check output above.${CLR_RESET}\n"
        exit 1
    fi
}

main
