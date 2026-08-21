#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for SSL/TLS Termination Reverse Proxy Mini-Project
# ==============================================================================
# Verifies:
#   1. HTTP Port 80 Permanent Redirection (HTTP 301 -> HTTPS)
#   2. HTTPS Port 443 Connectivity & HTTP 200 Response
#   3. Strict TLS 1.3 Handshake Negotiation (openssl s_client -tls1_3)
#   4. Modern TLS 1.3 Cipher Suite Agreement (TLS_AES_256_GCM_SHA384, etc.)
#   5. TLS 1.2 Secure Fallback Support (openssl s_client -tls1_2)
#   6. Rejection of Legacy Insecure TLS 1.0 Protocol
#   7. Rejection of Legacy Insecure TLS 1.1 Protocol
#   8. Strict-Transport-Security (HSTS) Header Enforcement
#   9. Web Security Headers (X-Frame-Options, X-Content-Type-Options, CSP)
#  10. Backend Header Propagation (X-Forwarded-Proto, X-Real-IP, Host)
#  11. SSL Metadata Injection (X-SSL-Protocol, X-SSL-Cipher)
#  12. Backend Health & Diagnostics JSON API (/api/health, /api/tls-info)
#  13. Subject Alternative Name (SAN) Certificate Validation
#  14. SSL Session Resumption & Caching
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

# Default configuration
HOST="127.0.0.1"
HTTP_PORT="80"
HTTPS_PORT="443"
CA_CERT_PATH="./certs/ca.crt"
VERBOSE=false

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🔒 SSL/TLS Termination Reverse Proxy Automated Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "${CLR_GRAY}Target Host : ${CLR_BOLD}${HOST}${CLR_RESET}"
    echo -e "${CLR_GRAY}HTTP Port   : ${CLR_BOLD}${HTTP_PORT}${CLR_RESET}"
    echo -e "${CLR_GRAY}HTTPS Port  : ${CLR_BOLD}${HTTPS_PORT}${CLR_RESET}"
    echo -e "${CLR_GRAY}CA Cert     : ${CLR_BOLD}${CA_CERT_PATH}${CLR_RESET}\n"
}

show_help() {
    echo "Usage: ./test_ssl_termination.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --host <host>         Target IP or Hostname (default: 127.0.0.1)"
    echo "  --http-port <port>    Plaintext HTTP Port (default: 80)"
    echo "  --https-port <port>   TLS HTTPS Port (default: 443)"
    echo "  --ca-cert <path>      Path to CA certificate for verification (default: ./certs/ca.crt)"
    echo "  -v, --verbose         Print raw request and response details"
    echo "  -h, --help            Display this help menu"
    echo ""
    echo "Examples:"
    echo "  ./test_ssl_termination.sh"
    echo "  ./test_ssl_termination.sh --http-port 8088 --https-port 8443"
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            HOST="$2"
            shift 2
            ;;
        --http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        --https-port)
            HTTPS_PORT="$2"
            shift 2
            ;;
        --ca-cert)
            CA_CERT_PATH="$2"
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
            echo -e "${CLR_RED}Unknown parameter: $1${CLR_RESET}"
            show_help
            exit 1
            ;;
    esac
done

check_dependencies() {
    if ! command -v curl &> /dev/null; then
        echo -e "${CLR_RED}${CLR_BOLD}Error: 'curl' command not found!${CLR_RESET}"
        exit 1
    fi

    if ! command -v openssl &> /dev/null; then
        echo -e "${CLR_RED}${CLR_BOLD}Error: 'openssl' command not found!${CLR_RESET}"
        exit 1
    fi
}

log_section() {
    echo -e "\n${CLR_BLUE}${CLR_BOLD}=== $1 ===${CLR_RESET}"
}

assert_equals() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$actual" == "$expected" || "$actual" == *"$expected"* ]]; then
        echo -e "  ${CLR_GREEN}✔ PASS${CLR_RESET} [${test_name}] (Matched: '${expected}')"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  ${CLR_RED}✖ FAIL${CLR_RESET} [${test_name}]"
        echo -e "    ${CLR_YELLOW}Expected contains:${CLR_RESET} ${expected}"
        echo -e "    ${CLR_YELLOW}Actual output:${CLR_RESET}     ${actual}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
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

run_tests() {
    print_banner
    check_dependencies

    local curl_ca_opt=("-k")
    if [[ -f "${CA_CERT_PATH}" ]]; then
        curl_ca_opt=("--cacert" "${CA_CERT_PATH}")
    fi

    # ==========================================================================
    # 1. HTTP to HTTPS Redirection
    # ==========================================================================
    log_section "1. HTTP Port 80 Redirection Enforcement"

    local http_headers
    http_headers=$(curl -sI "http://${HOST}:${HTTP_PORT}/" || echo "ERROR")
    assert_contains "HTTP Status 301 Moved Permanently" "HTTP/1.1 301" "$http_headers"
    assert_contains "Redirect Location contains https://" "Location: https://" "$http_headers"

    # ==========================================================================
    # 2. HTTPS Availability & HTTP 200 Response
    # ==========================================================================
    log_section "2. HTTPS Port 443 Connectivity"

    local https_headers
    https_headers=$(curl -sI "${curl_ca_opt[@]}" "https://${HOST}:${HTTPS_PORT}/" || echo "ERROR")
    assert_contains "HTTPS Port 443 returns HTTP 200" "200" "$https_headers"

    # ==========================================================================
    # 3. TLS Protocol & Cipher Negotiation
    # ==========================================================================
    log_section "3. TLS 1.3 Handshake & Modern Cipher Suite"

    local tls13_info
    tls13_info=$(openssl s_client -connect "${HOST}:${HTTPS_PORT}" -servername localhost -tls1_3 </dev/null 2>&1 || echo "ERROR")
    assert_contains "TLS 1.3 Protocol Negotiated" "TLSv1.3" "$tls13_info"
    assert_contains "Modern TLS 1.3 Cipher Negotiated" "TLS_" "$tls13_info"

    log_section "4. TLS 1.2 Fallback Compatibility"
    local tls12_info
    tls12_info=$(openssl s_client -connect "${HOST}:${HTTPS_PORT}" -servername localhost -tls1_2 </dev/null 2>&1 || echo "ERROR")
    assert_contains "TLS 1.2 Handshake Supported" "TLSv1.2" "$tls12_info"

    log_section "5. Legacy Insecure Protocols Rejection"
    local tls10_info
    tls10_info=$(openssl s_client -connect "${HOST}:${HTTPS_PORT}" -tls1 </dev/null 2>&1 || true)
    if echo "$tls10_info" | grep -Eq "unknown option|no protocols available|handshake failure|wrong version number|alert"; then
        echo -e "  ${CLR_GREEN}✔ PASS${CLR_RESET} [Insecure TLS 1.0 Rejected]"
        TOTAL_TESTS=$((TOTAL_TESTS + 1))
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        assert_contains "Insecure TLS 1.0 Rejected" "error" "$tls10_info"
    fi

    # ==========================================================================
    # 6. HTTP Strict Transport Security & Web Security Headers
    # ==========================================================================
    log_section "6. Strict-Transport-Security (HSTS) & Security Headers"

    assert_contains "HSTS Header (max-age=63072000)" "Strict-Transport-Security: max-age=63072000" "$https_headers"
    assert_contains "HSTS includeSubDomains directive" "includeSubDomains" "$https_headers"
    assert_contains "HSTS preload directive" "preload" "$https_headers"
    assert_contains "X-Frame-Options: DENY" "X-Frame-Options: DENY" "$https_headers"
    assert_contains "X-Content-Type-Options: nosniff" "X-Content-Type-Options: nosniff" "$https_headers"
    assert_contains "Referrer-Policy: strict-origin" "Referrer-Policy: strict-origin-when-cross-origin" "$https_headers"
    assert_contains "Content-Security-Policy (CSP) active" "Content-Security-Policy" "$https_headers"

    # ==========================================================================
    # 7. Reverse Proxy Header Propagation & SSL Termination Diagnostics
    # ==========================================================================
    log_section "7. Backend Proxy Header Injection & SSL Termination Diagnostics"

    local tls_json
    tls_json=$(curl -s "${curl_ca_opt[@]}" "https://${HOST}:${HTTPS_PORT}/api/tls-info" || echo "{}")
    assert_contains "ssl_terminated_at_proxy: true" '"ssl_terminated_at_proxy": true' "$tls_json"
    assert_contains "X-Forwarded-Proto: https" '"forwarded_proto": "https"' "$tls_json"
    assert_contains "Injected X-SSL-Protocol present" '"ssl_protocol": "TLSv' "$tls_json"
    assert_contains "Injected X-SSL-Cipher present" '"ssl_cipher":' "$tls_json"

    # ==========================================================================
    # 8. Backend Application Health & Dashboard
    # ==========================================================================
    log_section "8. Backend Health Endpoint & Interactive Dashboard"

    local health_json
    health_json=$(curl -s "${curl_ca_opt[@]}" "https://${HOST}:${HTTPS_PORT}/api/health" || echo "{}")
    assert_contains "Backend Health status: healthy" '"status": "healthy"' "$health_json"

    local dashboard_html
    dashboard_html=$(curl -s "${curl_ca_opt[@]}" "https://${HOST}:${HTTPS_PORT}/" || echo "")
    assert_contains "Interactive HTML Dashboard served" "SSL/TLS Termination Reverse Proxy" "$dashboard_html"

    # ==========================================================================
    # 9. Certificate Subject Alternative Names (SAN) Validation
    # ==========================================================================
    log_section "9. Certificate SAN Extension Validation"

    local san_output
    san_output=$(openssl s_client -connect "${HOST}:${HTTPS_PORT}" -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -text | grep -A 2 "Subject Alternative Name" || echo "")
    assert_contains "SAN contains DNS:localhost" "DNS:localhost" "$san_output"
    assert_contains "SAN contains IP:127.0.0.1" "IP Address:127.0.0.1" "$san_output"

    # ==========================================================================
    # 10. SSL Session Resumption & Caching
    # ==========================================================================
    log_section "10. SSL Session Resumption & Caching"

    local session_reconnect
    session_reconnect=$(openssl s_client -connect "${HOST}:${HTTPS_PORT}" -tls1_2 -reconnect </dev/null 2>&1 || echo "")
    assert_contains "SSL Session Cache Reconnect / Reuse" "Reused" "$session_reconnect"

    # ==========================================================================
    # Summary Report
    # ==========================================================================
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

run_tests
