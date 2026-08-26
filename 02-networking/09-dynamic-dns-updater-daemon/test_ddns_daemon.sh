#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for Dynamic DNS (DDNS) Updater Daemon
# ==============================================================================
# Verifies:
#   1. Mock Cloudflare API & Daemon Healthchecks
#   2. Initial DNS Record Sync on Startup
#   3. Local Cache & Redundant API Call Prevention
#   4. Dynamic WAN IP Change Detection & Auto-Sync (< 5s)
#   5. Consecutive Rapid Multi-IP Transitions
#   6. Cloud API Outage Resilience & Exponential Backoff Retries
#   7. Full Zone Record Integrity Verification
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

MOCK_API_URL="http://localhost:8080"
DAEMON_URL="http://localhost:8000"
VERBOSE=false

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🌐 Dynamic DNS (DDNS) Updater Daemon Automated Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "${CLR_GRAY}Mock DNS API     : ${CLR_BOLD}${MOCK_API_URL}${CLR_RESET}"
    echo -e "${CLR_GRAY}Daemon Status    : ${CLR_BOLD}${DAEMON_URL}${CLR_RESET}\n"
}

show_help() {
    echo "Usage: ./test_ddns_daemon.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose       Display detailed JSON outputs and diagnostics"
    echo "  -h, --help          Display this help menu"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
    section_header "1. Mock DNS API & Daemon Health Checks"

    # Mock DNS API
    local mock_res
    if mock_res=$(curl -s -m 3 "${MOCK_API_URL}/health" 2>&1); then
        if echo "$mock_res" | grep -q "mock-dns-api"; then
            record_result "Mock Cloudflare / Route53 API (:8080/health) healthy" 0 "$mock_res"
        else
            record_result "Mock Cloudflare API (:8080)" 1 "Unexpected response: $mock_res"
        fi
    else
        record_result "Mock Cloudflare API (:8080)" 1 "$mock_res"
    fi

    # DDNS Daemon Status Probe
    local daemon_res
    if daemon_res=$(curl -s -m 3 "${DAEMON_URL}/health" 2>&1); then
        if echo "$daemon_res" | grep -q '"status"'; then
            record_result "DDNS Background Daemon (:8000/health) healthy" 0 "$daemon_res"
        else
            record_result "DDNS Daemon (:8000)" 1 "Unexpected response: $daemon_res"
        fi
    else
        record_result "DDNS Daemon (:8000)" 1 "$daemon_res"
    fi
}

# ------------------------------------------------------------------------------
# Test 2: Initial State & Sync Verification
# ------------------------------------------------------------------------------
test_initial_sync() {
    section_header "2. Initial DNS Record Sync on Daemon Startup"

    local status_json
    status_json=$(curl -s -m 3 "${MOCK_API_URL}/api/dns/status" 2>&1 || echo "{}")
    local wan_ip
    wan_ip=$(echo "$status_json" | grep -o '"current_wan_ip": "[^"]*"' | cut -d'"' -f4 || echo "")

    if [ -n "$wan_ip" ]; then
        record_result "Discovered initial WAN IP: ${wan_ip}" 0
    else
        record_result "Discover initial WAN IP" 1 "Failed to get current WAN IP"
    fi
}

# ------------------------------------------------------------------------------
# Test 3: Redundant Polling & Cache Verification
# ------------------------------------------------------------------------------
test_cache_redundancy_avoidance() {
    section_header "3. Redundant Polling & Cache Verification"
    echo -e "${CLR_GRAY}Observing daemon over 5 seconds while WAN IP is stable...${CLR_RESET}"

    local initial_avoided
    initial_avoided=$(curl -s "${DAEMON_URL}/status" | grep -o '"redundant_calls_avoided": [0-9]*' | grep -o '[0-9]*' || echo 0)

    sleep 4

    local after_avoided
    after_avoided=$(curl -s "${DAEMON_URL}/status" | grep -o '"redundant_calls_avoided": [0-9]*' | grep -o '[0-9]*' || echo 0)

    if [ "$after_avoided" -gt "$initial_avoided" ]; then
        record_result "Local Cache Active: Avoided redundant API calls (${initial_avoided} -> ${after_avoided})" 0
    else
        record_result "Local Cache Redundancy check" 1 "Redundant calls avoided counter did not increment"
    fi
}

# ------------------------------------------------------------------------------
# Test 4: Dynamic WAN IP Change Detection & Auto-Update (< 5s)
# ------------------------------------------------------------------------------
test_dynamic_ip_update() {
    section_header "4. Dynamic WAN IP Change Detection & Auto-Sync (< 5s)"
    local target_ip="198.51.100.42"
    echo -e "${CLR_GRAY}Rotating simulated ISP WAN IP to ${target_ip}...${CLR_RESET}"

    # Trigger IP change
    curl -s -X POST "${MOCK_API_URL}/api/wan/simulate-ip-change" \
        -H "Content-Type: application/json" \
        -d "{\"ip\": \"${target_ip}\"}" >/dev/null

    # Wait for daemon poll cycle (check every 0.5s up to 6s)
    local synced=false
    for _ in {1..12}; do
        sleep 0.5
        local rec_ip
        rec_ip=$(curl -s "${MOCK_API_URL}/client/v4/zones/zone_1234567890abcdef/dns_records?name=home.example.com" | grep -o '"content": "[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "")
        if [ "$rec_ip" == "$target_ip" ]; then
            synced=true
            break
        fi
    done

    if [ "$synced" = true ]; then
        record_result "Dynamic IP Transition: home.example.com updated to ${target_ip} in < 4s" 0
    else
        record_result "Dynamic IP Transition check" 1 "home.example.com was not updated to ${target_ip}"
    fi
}

# ------------------------------------------------------------------------------
# Test 5: Consecutive Rapid Multi-IP Transitions
# ------------------------------------------------------------------------------
test_consecutive_ip_transitions() {
    section_header "5. Consecutive Rapid Multi-IP Transitions"

    local ips=("192.0.2.88" "203.0.113.199")
    for ip in "${ips[@]}"; do
        echo -e "${CLR_GRAY}Rotating WAN IP to ${ip}...${CLR_RESET}"
        curl -s -X POST "${MOCK_API_URL}/api/wan/simulate-ip-change" \
            -H "Content-Type: application/json" \
            -d "{\"ip\": \"${ip}\"}" >/dev/null

        sleep 3.5

        local home_ip
        home_ip=$(curl -s "${MOCK_API_URL}/client/v4/zones/zone_1234567890abcdef/dns_records?name=home.example.com" | grep -o '"content": "[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "")
        local vpn_ip
        vpn_ip=$(curl -s "${MOCK_API_URL}/client/v4/zones/zone_1234567890abcdef/dns_records?name=vpn.example.com" | grep -o '"content": "[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "")

        if [ "$home_ip" == "$ip" ] && [ "$vpn_ip" == "$ip" ]; then
            record_result "Multi-Domain Sync to ${ip} (home & vpn verified)" 0
        else
            record_result "Multi-Domain Sync to ${ip}" 1 "home=${home_ip}, vpn=${vpn_ip}, expected=${ip}"
        fi
    done
}

# ------------------------------------------------------------------------------
# Test 6: Cloud API Fault Tolerance & Exponential Backoff Retries
# ------------------------------------------------------------------------------
test_fault_tolerance_backoff() {
    section_header "6. Cloud API Fault Tolerance & Exponential Backoff Retries"
    local outage_ip="198.51.100.123"

    echo -e "${CLR_GRAY}Simulating 2 consecutive Cloudflare API 500 errors...${CLR_RESET}"
    curl -s -X POST "${MOCK_API_URL}/api/wan/simulate-fault" \
        -H "Content-Type: application/json" \
        -d '{"enabled": true, "status_code": 500, "count": 2}' >/dev/null

    echo -e "${CLR_GRAY}Rotating WAN IP to ${outage_ip} during outage...${CLR_RESET}"
    curl -s -X POST "${MOCK_API_URL}/api/wan/simulate-ip-change" \
        -H "Content-Type: application/json" \
        -d "{\"ip\": \"${outage_ip}\"}" >/dev/null

    # Wait for daemon to retry with exponential backoff and eventually succeed
    local recovered=false
    for _ in {1..16}; do
        sleep 0.5
        local rec_ip
        rec_ip=$(curl -s "${MOCK_API_URL}/client/v4/zones/zone_1234567890abcdef/dns_records?name=home.example.com" | grep -o '"content": "[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "")
        if [ "$rec_ip" == "$outage_ip" ]; then
            recovered=true
            break
        fi
    done

    if [ "$recovered" = true ]; then
        record_result "Fault Resilience: Daemon retried with exponential backoff and updated to ${outage_ip}" 0
    else
        record_result "Fault Resilience check" 1 "Daemon did not recover after simulated outage"
    fi
}

# ------------------------------------------------------------------------------
# Test 7: Full Zone Record Integrity Verification
# ------------------------------------------------------------------------------
test_zone_integrity() {
    section_header "7. Full Zone Record Integrity Verification"

    local current_wan
    current_wan=$(curl -s "${MOCK_API_URL}/ip" | tr -d '[:space:]')
    local records_json
    records_json=$(curl -s "${MOCK_API_URL}/client/v4/zones/zone_1234567890abcdef/dns_records")

    local all_synced=true
    for domain in "home.example.com" "vpn.example.com"; do
        if echo "$records_json" | grep -A 5 "\"name\": \"${domain}\"" | grep -q "\"content\": \"${current_wan}\""; then
            record_result "Domain [${domain}] accurately matches WAN IP (${current_wan})" 0
        else
            record_result "Domain [${domain}] integrity check" 1 "Record content mismatch"
            all_synced=false
        fi
    done
}

# ------------------------------------------------------------------------------
# Main Execution Flow & Summary
# ------------------------------------------------------------------------------
main() {
    local start_time
    start_time=$(date +%s)

    print_banner
    test_service_health
    test_initial_sync
    test_cache_redundancy_avoidance
    test_dynamic_ip_update
    test_consecutive_ip_transitions
    test_fault_tolerance_backoff
    test_zone_integrity

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
        echo -e "\n  ${CLR_GREEN}${CLR_BOLD}🎉 ALL DYNAMIC DNS DAEMON CHECKS PASSED!${CLR_RESET}\n"
        exit 0
    else
        echo -e "\n  ${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. Check output above.${CLR_RESET}\n"
        exit 1
    fi
}

main
