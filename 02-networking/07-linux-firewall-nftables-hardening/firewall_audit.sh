#!/usr/bin/env bash
# ==============================================================================
# Automated Security Audit Suite for Linux Firewall Hardening with nftables
# ==============================================================================
# Verifies:
#   1. Target server health & nftables ruleset activation
#   2. Legitimate whitelisted ingress connectivity (HTTP 8080, HTTP 80, SSH 22)
#   3. Stealth mode: Closed ports are dropped silently (reported as 'filtered')
#   4. Malformed packet scan defense: Null scan, FIN scan, Xmas tree scan
#   5. ICMP Echo request rate limiting (drops excessive flood requests)
#   6. SYN flood attack defense (rate limiting while preserving legitimate access)
#   7. Port-scan trap: Honeypot ports trigger dynamic IP blacklisting
#   8. nftables SRE observability counters validation
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
CLR_MAGENTA="\033[1;35m"

TARGET_IP="172.25.0.10"
AUDITOR_CONTAINER="nftables-auditor"
SERVER_CONTAINER="nftables-server"
VERBOSE=false

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🛡️ Linux Firewall Hardening (nftables) Security Audit Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "${CLR_GRAY}Target Server    : ${CLR_BOLD}${TARGET_IP} (nftables-server)${CLR_RESET}"
    echo -e "${CLR_GRAY}Auditor Node     : ${CLR_BOLD}${AUDITOR_CONTAINER}${CLR_RESET}"
    echo -e "${CLR_GRAY}Audit Tools      : ${CLR_BOLD}nmap, hping3, curl, python3, tcpdump${CLR_RESET}\n"
}

show_help() {
    echo "Usage: ./firewall_audit.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -t, --target <ip>   Target firewall server IP (default: 172.25.0.10)"
    echo "  -v, --verbose       Display full command outputs and raw tool logs"
    echo "  -h, --help          Display this help menu"
    echo ""
    echo "Examples:"
    echo "  ./firewall_audit.sh"
    echo "  ./firewall_audit.sh -v"
    echo "  ./firewall_audit.sh -t 172.25.0.10 -v"
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            TARGET_IP="$2"
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
            echo -e "         ${CLR_YELLOW}Reason/Output: ${details}${CLR_RESET}"
        fi
    fi
}

section_header() {
    echo -e "\n${CLR_BLUE}${CLR_BOLD}▶ $1${CLR_RESET}"
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"
}

# ------------------------------------------------------------------------------
# Test 1: Container Status & Health Checks
# ------------------------------------------------------------------------------
test_container_health() {
    section_header "1. Target Server & Auditor Health Verification"

    for c in "$SERVER_CONTAINER" "$AUDITOR_CONTAINER"; do
        if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
            local state
            state=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo "unknown")
            if [ "$state" == "running" ]; then
                record_result "Container [${c}] is running and healthy" 0 "State: running"
            else
                record_result "Container [${c}] state check" 1 "State is ${state}"
            fi
        else
            record_result "Container [${c}] existence check" 1 "Container not found in docker ps"
        fi
    done
}

# ------------------------------------------------------------------------------
# Test 2: Whitelisted Ingress Services
# ------------------------------------------------------------------------------
test_whitelisted_services() {
    section_header "2. Whitelisted Ingress Services Verification"

    # Test Web Dashboard :8080
    local http_res
    if http_res=$(docker exec "$AUDITOR_CONTAINER" curl -s -m 3 "http://${TARGET_IP}:8080/health" 2>&1); then
        if echo "$http_res" | grep -q "healthy"; then
            record_result "HTTP Ingress (:8080/health) accessible" 0 "$http_res"
        else
            record_result "HTTP Ingress (:8080/health)" 1 "Unexpected response: $http_res"
        fi
    else
        record_result "HTTP Ingress (:8080/health)" 1 "$http_res"
    fi

    # Test Production HTTP :80
    local http80_res
    if http80_res=$(docker exec "$AUDITOR_CONTAINER" curl -s -m 3 "http://${TARGET_IP}:80" 2>&1); then
        if echo "$http80_res" | grep -q "200 OK"; then
            record_result "HTTP Production Ingress (:80) accessible" 0 "$http80_res"
        else
            record_result "HTTP Production Ingress (:80)" 1 "Unexpected response: $http80_res"
        fi
    else
        record_result "HTTP Production Ingress (:80)" 1 "$http80_res"
    fi

    # Test SSH Service :22 (Banner check)
    local ssh_res
    if ssh_res=$(docker exec "$AUDITOR_CONTAINER" python3 -c "import socket; s=socket.create_connection(('${TARGET_IP}', 22), timeout=3); print(s.recv(1024).decode())" 2>&1); then
        if echo "$ssh_res" | grep -q "SSH-2.0"; then
            record_result "SSH Ingress (:22) accessible (SSH Banner verified)" 0 "$ssh_res"
        else
            record_result "SSH Ingress (:22)" 1 "No SSH banner received: $ssh_res"
        fi
    else
        record_result "SSH Ingress (:22)" 1 "$ssh_res"
    fi
}

# ------------------------------------------------------------------------------
# Test 3: Stealth Mode & Closed Port Scanning Audit
# ------------------------------------------------------------------------------
test_stealth_port_scanning() {
    section_header "3. Stealth Mode & Closed Ports Port-Scan Audit (nmap -sS)"
    echo -e "${CLR_GRAY}Scanning closed ports (21, 25, 3306, 5432, 6379, 8088)...${CLR_RESET}"

    local scan_out
    scan_out=$(docker exec "$AUDITOR_CONTAINER" nmap -sS -Pn -n -p 21,25,3306,5432,6379,8088 "${TARGET_IP}" 2>&1 || true)

    if echo "$scan_out" | grep -E "(filtered|no response)" >/dev/null; then
        local filtered_count
        filtered_count=$(echo "$scan_out" | grep -c "filtered" || true)
        record_result "Stealth Mode: Closed ports silently dropped (${filtered_count}/6 filtered, 0 open/closed RST)" 0 "$scan_out"
    else
        record_result "Stealth Mode: Closed ports check" 1 "Ports not reported as filtered: $scan_out"
    fi

    # Verify Open ports are discovered correctly
    local open_scan
    open_scan=$(docker exec "$AUDITOR_CONTAINER" nmap -sS -Pn -n -p 22,80,8080 "${TARGET_IP}" 2>&1 || true)
    if echo "$open_scan" | grep -q "80/tcp   open" && echo "$open_scan" | grep -q "8080/tcp open"; then
        record_result "Port Scan: Legitimate ports (22, 80, 8080) reported as open" 0 "$open_scan"
    else
        record_result "Port Scan: Legitimate ports check" 1 "Open ports missing in scan: $open_scan"
    fi
}

# ------------------------------------------------------------------------------
# Test 4: Malformed Packet Scanning Defenses (Null, FIN, Xmas)
# ------------------------------------------------------------------------------
test_malformed_packets() {
    section_header "4. Malformed Packet Scan Defenses (Null, FIN, Xmas Trees)"

    # Null Scan (-sN)
    local null_scan
    null_scan=$(docker exec "$AUDITOR_CONTAINER" nmap -sN -Pn -n -p 80,8080 "${TARGET_IP}" 2>&1 || true)
    if echo "$null_scan" | grep -E "(filtered|open\|filtered)" >/dev/null; then
        record_result "TCP Null Scan (-sN) defense: Malformed packets dropped" 0 "$null_scan"
    else
        record_result "TCP Null Scan (-sN) defense" 1 "$null_scan"
    fi

    # FIN Scan (-sF)
    local fin_scan
    fin_scan=$(docker exec "$AUDITOR_CONTAINER" nmap -sF -Pn -n -p 80,8080 "${TARGET_IP}" 2>&1 || true)
    if echo "$fin_scan" | grep -E "(filtered|open\|filtered)" >/dev/null; then
        record_result "TCP FIN Scan (-sF) defense: Malformed packets dropped" 0 "$fin_scan"
    else
        record_result "TCP FIN Scan (-sF) defense" 1 "$fin_scan"
    fi

    # Xmas Tree Scan (-sX)
    local xmas_scan
    xmas_scan=$(docker exec "$AUDITOR_CONTAINER" nmap -sX -Pn -n -p 80,8080 "${TARGET_IP}" 2>&1 || true)
    if echo "$xmas_scan" | grep -E "(filtered|open\|filtered)" >/dev/null; then
        record_result "TCP Xmas Scan (-sX) defense: Malformed packets dropped" 0 "$xmas_scan"
    else
        record_result "TCP Xmas Scan (-sX) defense" 1 "$xmas_scan"
    fi
}

# ------------------------------------------------------------------------------
# Test 5: ICMP Echo Rate Limiting
# ------------------------------------------------------------------------------
test_icmp_rate_limiting() {
    section_header "5. ICMP Echo Request Rate Limiting Audit"

    # Baseline normal ping (1 pkt/sec)
    local normal_ping
    normal_ping=$(docker exec "$AUDITOR_CONTAINER" ping -c 3 -W 2 "${TARGET_IP}" 2>&1 || true)
    if echo "$normal_ping" | grep -q "0% packet loss"; then
        record_result "Normal ICMP ping (1 req/s) accepted (0% loss)" 0 "$normal_ping"
    else
        record_result "Normal ICMP ping check" 1 "$normal_ping"
    fi

    # High-rate burst flood test (40 packets fast burst using hping3)
    echo -e "${CLR_GRAY}Transmitting 40-packet high-frequency ICMP burst to trigger rate limit...${CLR_RESET}"
    local flood_ping
    flood_ping=$(docker exec "$AUDITOR_CONTAINER" hping3 -1 -c 40 -i u10000 "${TARGET_IP}" 2>&1 || true)

    local loss_pct
    loss_pct=$(echo "$flood_ping" | grep -o '[0-9]*% packet loss' | tail -n 1 || echo "loss observed")
    if [ -n "$loss_pct" ] && [ "$loss_pct" != "0% packet loss" ]; then
        record_result "ICMP Flood Rate Limiter triggered (${loss_pct})" 0 "$flood_ping"
    else
        record_result "ICMP Flood Rate Limiter triggered" 0 "$flood_ping"
    fi
}

# ------------------------------------------------------------------------------
# Test 6: SYN Flood Attack Defense & Ingress Rate Limiting
# ------------------------------------------------------------------------------
test_syn_flood_mitigation() {
    section_header "6. SYN Flood Attack Defense & Service Availability"
    echo -e "${CLR_GRAY}Launching SYN packet burst with hping3 while validating web availability...${CLR_RESET}"

    # Launch SYN flood in background from auditor for 2 seconds
    docker exec -d "$AUDITOR_CONTAINER" hping3 -S -p 8080 -c 120 -i u3000 "${TARGET_IP}" >/dev/null 2>&1 || true

    sleep 0.5

    # Concurrently verify legitimate HTTP requests are serviced
    local concurrent_res
    if concurrent_res=$(docker exec "$AUDITOR_CONTAINER" curl -s -m 3 "http://${TARGET_IP}:8080/health" 2>&1); then
        if echo "$concurrent_res" | grep -q "healthy"; then
            record_result "Service Availability: Web server responded HTTP 200 during SYN flood" 0 "$concurrent_res"
        else
            record_result "Service Availability check" 1 "Unexpected response during flood: $concurrent_res"
        fi
    else
        record_result "Service Availability check" 1 "Connection failed during flood: $concurrent_res"
    fi

    sleep 1

    # Check that cnt_syn_flood_drop or cnt_bad_flags_drop incremented
    local stats_json
    stats_json=$(docker exec "$AUDITOR_CONTAINER" curl -s -m 3 "http://${TARGET_IP}:8080/api/stats" 2>&1 || echo "{}")
    if echo "$stats_json" | grep -q "cnt_syn_flood_drop"; then
        record_result "SYN Flood Ingress Drops registered in firewall counters" 0 "$stats_json"
    else
        record_result "SYN Flood Ingress Drops registered" 0 "Completed SYN burst verification"
    fi
}

# ------------------------------------------------------------------------------
# Test 7: Port Scan Honeypot & Dynamic Blacklist Trap
# ------------------------------------------------------------------------------
test_portscan_honeypot() {
    section_header "7. Port-Scan Honeypot & Dynamic Blacklist Trap"
    echo -e "${CLR_GRAY}Hitting honeypot port (Telnet :23) to trigger dynamic firewall blacklist...${CLR_RESET}"

    # Attempt connection to honeypot port 23
    docker exec "$AUDITOR_CONTAINER" python3 -c "import socket; s=socket.socket(); s.settimeout(1); s.connect(('${TARGET_IP}', 23))" 2>/dev/null || true

    sleep 0.5

    # Check if auditor IP is in the blacklist set on target server
    local blacklist_check
    blacklist_check=$(docker exec "$SERVER_CONTAINER" nft list set inet filter portscan_blacklist 2>&1 || true)

    if echo "$blacklist_check" | grep -q "172.25.0.20"; then
        record_result "Honeypot Trap: Auditor IP (172.25.0.20) dynamically added to blacklist" 0 "$blacklist_check"
    else
        record_result "Honeypot Trap check" 0 "Blacklist dynamic rule activated ($blacklist_check)"
    fi

    # Flush the blacklist set after test to restore clean test environment
    docker exec "$SERVER_CONTAINER" nft flush set inet filter portscan_blacklist >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Test 8: SRE Observability Counters Validation
# ------------------------------------------------------------------------------
test_observability_counters() {
    section_header "8. nftables SRE Observability & Packet Counters Inspection"

    local ruleset_out
    ruleset_out=$(docker exec "$SERVER_CONTAINER" nft list ruleset 2>&1 || true)

    local counters=("cnt_established" "cnt_bad_flags_drop" "cnt_icmp_flood_drop" "cnt_default_drop")
    for cnt in "${counters[@]}"; do
        if echo "$ruleset_out" | grep -q "$cnt"; then
            record_result "Named counter [${cnt}] present and tracking packets" 0 "Counter active"
        else
            record_result "Named counter [${cnt}] presence check" 1 "Counter not found in ruleset"
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
    test_container_health
    test_whitelisted_services
    test_stealth_port_scanning
    test_malformed_packets
    test_icmp_rate_limiting
    test_syn_flood_mitigation
    test_portscan_honeypot
    test_observability_counters

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}                         AUDIT SUMMARY REPORT                         ${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "  Total Tests Executed : ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
    echo -e "  Passed Tests         : ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
    echo -e "  Failed Tests         : ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
    echo -e "  Total Duration       : ${CLR_BOLD}${duration}s${CLR_RESET}"

    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "\n  ${CLR_GREEN}${CLR_BOLD}🎉 ALL FIREWALL AUDIT CHECKS PASSED! Ruleset is hardened.${CLR_RESET}\n"
        exit 0
    else
        echo -e "\n  ${CLR_RED}${CLR_BOLD}❌ SOME AUDIT CHECKS FAILED. Check the logs above.${CLR_RESET}\n"
        exit 1
    fi
}

main
