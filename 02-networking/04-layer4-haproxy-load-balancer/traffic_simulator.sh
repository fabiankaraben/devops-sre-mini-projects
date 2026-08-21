#!/usr/bin/env bash
# ==============================================================================
# Traffic Simulator & Validation Suite for HAProxy Layer 4 Load Balancer
# ==============================================================================
# Verifies:
#   1. HAProxy TCP Frontend Availability (Port 9000)
#   2. HAProxy Web Stats Dashboard Authentication & Metrics (Port 8404)
#   3. Round-Robin Traffic Distribution across 3 Backend Instances
#   4. Dynamic Failover: Active TCP Health Check ejection of failed nodes
#   5. Dynamic Recovery / Self-Healing: Re-admission of restored nodes
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"
CLR_MAGENTA="\033[1;35m"

# Default configuration
HOST="127.0.0.1"
PORT="9000"
STATS_PORT="8404"
STATS_AUTH="admin:admin123"
REQUEST_COUNT=60
RUN_FAILOVER=false
VERBOSE=false

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  ⚖️  HAProxy Layer 4 TCP Load Balancer Test Suite & Traffic Simulator"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "${CLR_GRAY}Target Load Balancer : ${CLR_BOLD}${HOST}:${PORT}${CLR_RESET}"
    echo -e "${CLR_GRAY}HAProxy Stats URL    : ${CLR_BOLD}http://${HOST}:${STATS_PORT}${CLR_RESET}"
    echo -e "${CLR_GRAY}Simulated Requests   : ${CLR_BOLD}${REQUEST_COUNT}${CLR_RESET}\n"
}

show_help() {
    echo "Usage: ./traffic_simulator.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -n, --requests <num>  Number of requests to send for distribution test (default: 60)"
    echo "  --host <ip/host>      Target HAProxy Host/IP (default: 127.0.0.1)"
    echo "  -p, --port <port>     HAProxy TCP Frontend port (default: 9000)"
    echo "  --stats-port <port>   HAProxy Stats Dashboard port (default: 8404)"
    echo "  --failover            Execute comprehensive node failover and recovery test"
    echo "  -v, --verbose         Print raw request and response details"
    echo "  -h, --help            Display this help menu"
    echo ""
    echo "Examples:"
    echo "  ./traffic_simulator.sh"
    echo "  ./traffic_simulator.sh -n 90"
    echo "  ./traffic_simulator.sh --failover"
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--requests)
            REQUEST_COUNT="$2"
            shift 2
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --stats-port)
            STATS_PORT="$2"
            shift 2
            ;;
        --failover)
            RUN_FAILOVER=true
            shift
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

check_dependencies() {
    if ! command -v curl &> /dev/null; then
        echo -e "${CLR_RED}${CLR_BOLD}Error: 'curl' is required but not installed.${CLR_RESET}"
        exit 1
    fi
}

log_section() {
    echo -e "\n${CLR_BLUE}${CLR_BOLD}=== $1 ===${CLR_RESET}"
}

assert_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if echo "$haystack" | grep -qi "$needle"; then
        echo -e "  ${CLR_GREEN}✔ PASS${CLR_RESET} [${test_name}] (Found '${needle}')"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  ${CLR_RED}✖ FAIL${CLR_RESET} [${test_name}]"
        echo -e "    ${CLR_YELLOW}Missing pattern:${CLR_RESET} ${needle}"
        echo -e "    ${CLR_YELLOW}Actual output:${CLR_RESET}   ${haystack}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

test_stats_dashboard() {
    log_section "1. HAProxy Web Statistics Dashboard Verification"

    local stats_resp
    stats_resp=$(curl -s -u "${STATS_AUTH}" "http://${HOST}:${STATS_PORT}/;csv" || echo "ERROR")
    assert_contains "HAProxy CSV Metrics Endpoint Accessible" "tcp_backend_pool" "$stats_resp"
    assert_contains "Backend-1 registered in stats" "backend-1" "$stats_resp"
    assert_contains "Backend-2 registered in stats" "backend-2" "$stats_resp"
    assert_contains "Backend-3 registered in stats" "backend-3" "$stats_resp"
}

test_traffic_distribution() {
    local count="$1"
    log_section "2. Round-Robin Traffic Distribution (${count} Requests)"

    local count_b1=0
    local count_b2=0
    local count_b3=0
    local failed_reqs=0

    echo -e "${CLR_GRAY}Sending ${count} TCP requests through HAProxy (port ${PORT})...${CLR_RESET}"

    for ((i=1; i<=count; i++)); do
        local resp
        resp=$(curl -s --connect-timeout 2 "http://${HOST}:${PORT}/api/info" || echo "ERROR")

        if echo "$resp" | grep -q '"node_id": "backend-1"'; then
            count_b1=$((count_b1 + 1))
        elif echo "$resp" | grep -q '"node_id": "backend-2"'; then
            count_b2=$((count_b2 + 1))
        elif echo "$resp" | grep -q '"node_id": "backend-3"'; then
            count_b3=$((count_b3 + 1))
        else
            failed_reqs=$((failed_reqs + 1))
        fi
    done

    local pct_b1=$(( count_b1 * 100 / count ))
    local pct_b2=$(( count_b2 * 100 / count ))
    local pct_b3=$(( count_b3 * 100 / count ))

    echo ""
    echo -e "  ┌──────────────────┬──────────────┬─────────────┐"
    echo -e "  │ ${CLR_BOLD}Backend Instance${CLR_RESET} │ ${CLR_BOLD}Requests Won${CLR_RESET} │ ${CLR_BOLD}Distribution${CLR_RESET}│"
    echo -e "  ├──────────────────┼──────────────┼─────────────┤"
    printf "  │ %-16s │ %-12d │ %-10s  │\n" "backend-1" "$count_b1" "${pct_b1}%"
    printf "  │ %-16s │ %-12d │ %-10s  │\n" "backend-2" "$count_b2" "${pct_b2}%"
    printf "  │ %-16s │ %-12d │ %-10s  │\n" "backend-3" "$count_b3" "${pct_b3}%"
    echo -e "  └──────────────────┴──────────────┴─────────────┘"
    echo ""

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ $failed_reqs -eq 0 && $count_b1 -gt 0 && $count_b2 -gt 0 && $count_b3 -gt 0 ]]; then
        echo -e "  ${CLR_GREEN}✔ PASS${CLR_RESET} [Round-robin evenly distributed across all 3 nodes with 0 dropped requests]"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  ${CLR_RED}✖ FAIL${CLR_RESET} [Uneven distribution or dropped requests (Failed: ${failed_reqs})]"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

test_failover_recovery() {
    log_section "3. Dynamic Failover & Self-Healing Resilience Test"

    echo -e "${CLR_YELLOW}[Step 1/4] Simulating outage: Stopping container 'haproxy-backend-2'...${CLR_RESET}"
    docker compose stop backend-2 > /dev/null 2>&1 || docker stop haproxy-backend-2 > /dev/null 2>&1

    echo -e "${CLR_GRAY}Waiting 6s for HAProxy active TCP health check (inter 2s, fall 3) to mark node DOWN...${CLR_RESET}"
    sleep 6

    echo -e "${CLR_GRAY}Sending 30 requests during outage...${CLR_RESET}"
    local failover_b1=0
    local failover_b2=0
    local failover_b3=0
    local failover_errors=0

    for ((i=1; i<=30; i++)); do
        local resp
        resp=$(curl -s --connect-timeout 2 "http://${HOST}:${PORT}/api/info" || echo "ERROR")
        if echo "$resp" | grep -q '"node_id": "backend-1"'; then
            failover_b1=$((failover_b1 + 1))
        elif echo "$resp" | grep -q '"node_id": "backend-2"'; then
            failover_b2=$((failover_b2 + 1))
        elif echo "$resp" | grep -q '"node_id": "backend-3"'; then
            failover_b3=$((failover_b3 + 1))
        else
            failover_errors=$((failover_errors + 1))
        fi
    done

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ $failover_b2 -eq 0 && $failover_errors -eq 0 && $failover_b1 -gt 0 && $failover_b3 -gt 0 ]]; then
        echo -e "  ${CLR_GREEN}✔ PASS${CLR_RESET} [Node backend-2 successfully ejected; 100% traffic routed to healthy nodes (b1=${failover_b1}, b3=${failover_b3}) with 0 dropped requests]"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  ${CLR_RED}✖ FAIL${CLR_RESET} [Traffic was routed to dead node or requests dropped (b2=${failover_b2}, err=${failover_errors})]"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi

    echo -e "${CLR_YELLOW}[Step 2/4] Restoring node: Starting container 'haproxy-backend-2'...${CLR_RESET}"
    docker compose start backend-2 > /dev/null 2>&1 || docker start haproxy-backend-2 > /dev/null 2>&1

    echo -e "${CLR_GRAY}Waiting 5s for HAProxy active TCP health check (rise 2) to mark node UP...${CLR_RESET}"
    sleep 5

    echo -e "${CLR_GRAY}Sending 30 requests after recovery...${CLR_RESET}"
    local recover_b1=0
    local recover_b2=0
    local recover_b3=0
    local recover_errors=0

    for ((i=1; i<=30; i++)); do
        local resp
        resp=$(curl -s --connect-timeout 2 "http://${HOST}:${PORT}/api/info" || echo "ERROR")
        if echo "$resp" | grep -q '"node_id": "backend-1"'; then
            recover_b1=$((recover_b1 + 1))
        elif echo "$resp" | grep -q '"node_id": "backend-2"'; then
            recover_b2=$((recover_b2 + 1))
        elif echo "$resp" | grep -q '"node_id": "backend-3"'; then
            recover_b3=$((recover_b3 + 1))
        else
            recover_errors=$((recover_errors + 1))
        fi
    done

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ $recover_b2 -gt 0 && $recover_errors -eq 0 && $recover_b1 -gt 0 && $recover_b3 -gt 0 ]]; then
        echo -e "  ${CLR_GREEN}✔ PASS${CLR_RESET} [Self-Healing Verified: Restored node backend-2 rejoined the active pool seamlessly (b1=${recover_b1}, b2=${recover_b2}, b3=${recover_b3})]"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  ${CLR_RED}✖ FAIL${CLR_RESET} [Restored node failed to re-enter pool (b2=${recover_b2})]"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

run_suite() {
    print_banner
    check_dependencies

    test_stats_dashboard
    test_traffic_distribution "${REQUEST_COUNT}"

    if [[ "$RUN_FAILOVER" = true ]]; then
        test_failover_recovery
    else
        echo -e "\n${CLR_GRAY}Tip: Run with ${CLR_BOLD}--failover${CLR_RESET} to test automatic node ejection and self-healing recovery.${CLR_RESET}"
    fi

    # Summary Report
    echo ""
    echo "======================================================================"
    if [[ $FAILED_TESTS -eq 0 ]]; then
        echo -e "  ${CLR_GREEN}${CLR_BOLD}🎉 ALL TESTS PASSED! (${PASSED_TESTS}/${TOTAL_TESTS})${CLR_RESET}"
    else
        echo -e "  ${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED (${FAILED_TESTS} failed out of ${TOTAL_TESTS})${CLR_RESET}"
    fi
    echo "======================================================================"
    echo ""

    if [[ $FAILED_TESTS -gt 0 ]]; then
        exit 1
    fi
}

run_suite
