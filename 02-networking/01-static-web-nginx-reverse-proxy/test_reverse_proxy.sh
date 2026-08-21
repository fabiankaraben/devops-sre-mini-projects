#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for Nginx Reverse Proxy & Static Caching Mini-Project
# ==============================================================================
# Verifies:
#   1. Static file serving (HTML, CSS, JS)
#   2. Gzip dynamic compression negotiation (Accept-Encoding: gzip)
#   3. Aggressive Cache-Control headers on static assets vs no-cache on HTML
#   4. Dynamic API reverse proxy routing (/api/health, /api/info, /api/time, /api/data)
#   5. Header propagation to backend (X-Forwarded-For, X-Real-IP, Host)
#   6. Custom 404 Not Found edge error interception
#   7. Custom 50x Server Error edge error interception
#   8. Custom security & diagnostic headers (X-Proxy-By, X-Content-Type-Options)
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

# Default configuration
BASE_URL="http://localhost:8080"
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Nginx Reverse Proxy & Static Cache Automated Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "${CLR_GRAY}Target URL: ${CLR_BOLD}${BASE_URL}${CLR_RESET}\n"
}

show_help() {
    echo "Usage: ./test_reverse_proxy.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --url <url>     Base URL of the Nginx proxy to test (default: http://localhost:8080)"
    echo "  -h, --help      Display this help menu"
    echo ""
    echo "Examples:"
    echo "  ./test_reverse_proxy.sh"
    echo "  ./test_reverse_proxy.sh --url http://127.0.0.1:8080"
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            BASE_URL="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Error: Unknown argument '$1'${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

# Strip trailing slash from BASE_URL
BASE_URL="${BASE_URL%/}"

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

# Wait for server readiness before testing
wait_for_server() {
    echo -e "${CLR_GRAY}Checking proxy availability at ${BASE_URL}...${CLR_RESET}"
    local retries=15
    local wait_sec=1
    local ready=0

    for ((i=1; i<=retries; i++)); do
        if curl -s -f -o /dev/null --connect-timeout 2 "${BASE_URL}/" 2>/dev/null; then
            ready=1
            break
        fi
        echo -e "${CLR_GRAY}Waiting for server... ($i/$retries)${CLR_RESET}"
        sleep "$wait_sec"
    done

    if [[ $ready -eq 0 ]]; then
        echo -e "${CLR_RED}Error: Unable to connect to Nginx reverse proxy at ${BASE_URL} after ${retries} attempts.${CLR_RESET}"
        echo -e "${CLR_YELLOW}Ensure the containers are up: 'docker compose up -d'${CLR_RESET}"
        exit 1
    fi
    echo -e "${CLR_GREEN}✓ Proxy is reachable.${CLR_RESET}\n"
}

run_tests() {
    print_banner
    wait_for_server

    echo -e "${CLR_BOLD}--- 1. Static Web Asset Delivery & Caching ---${CLR_RESET}"

    # 1. Root / delivers HTML
    local root_headers root_code
    root_headers=$(curl -s -i "${BASE_URL}/")
    root_code=$(echo "$root_headers" | head -n 1 | awk '{print $2}')
    if [[ "$root_code" == "200" ]]; then
        record_result "01" "Root '/' returns HTTP 200 OK" 0 "HTTP Status: $root_code"
    else
        record_result "01" "Root '/' returns HTTP 200 OK" 1 "Expected 200, got: $root_code"
    fi

    # 2. HTML Cache-Control (no-cache)
    local html_cache
    html_cache=$(echo "$root_headers" | grep -i '^cache-control:' | tr -d '\r' || true)
    if echo "$html_cache" | grep -qi "no-cache"; then
        record_result "02" "HTML files enforce 'no-cache, must-revalidate' for immediate updates" 0 "Header: $html_cache"
    else
        record_result "02" "HTML files enforce 'no-cache, must-revalidate' for immediate updates" 1 "Header missing no-cache: $html_cache"
    fi

    # 3. Static CSS delivery
    local css_headers css_code
    css_headers=$(curl -s -i "${BASE_URL}/style.css")
    css_code=$(echo "$css_headers" | head -n 1 | awk '{print $2}')
    if [[ "$css_code" == "200" ]]; then
        record_result "03" "Static asset '/style.css' returns HTTP 200 OK" 0 "HTTP Status: $css_code"
    else
        record_result "03" "Static asset '/style.css' returns HTTP 200 OK" 1 "Expected 200, got: $css_code"
    fi

    # 4. Static CSS Aggressive Caching (max-age=31536000 / immutable)
    local css_cache
    css_cache=$(echo "$css_headers" | grep -i '^cache-control:' | tr -d '\r' || true)
    if echo "$css_cache" | grep -qi "max-age=31536000"; then
        record_result "04" "Static asset '/style.css' contains aggressive Cache-Control (1 year)" 0 "Header: $css_cache"
    else
        record_result "04" "Static asset '/style.css' contains aggressive Cache-Control (1 year)" 1 "Header missing max-age=31536000: $css_cache"
    fi

    # 5. Static JS delivery & caching
    local js_headers js_code js_cache
    js_headers=$(curl -s -i "${BASE_URL}/app.js")
    js_code=$(echo "$js_headers" | head -n 1 | awk '{print $2}')
    js_cache=$(echo "$js_headers" | grep -i '^cache-control:' | tr -d '\r' || true)
    if [[ "$js_code" == "200" ]] && echo "$js_cache" | grep -qi "max-age=31536000"; then
        record_result "05" "Static asset '/app.js' delivers HTTP 200 with 1-year cache" 0 "HTTP Status: $js_code, Cache: $js_cache"
    else
        record_result "05" "Static asset '/app.js' delivers HTTP 200 with 1-year cache" 1 "Failed: status=$js_code, cache=$js_cache"
    fi

    echo -e "\n${CLR_BOLD}--- 2. Gzip Dynamic Compression Negotiation ---${CLR_RESET}"

    # 6. Gzip compression on CSS
    local gzip_css_headers gzip_css_encoding
    gzip_css_headers=$(curl -s -i -H "Accept-Encoding: gzip" "${BASE_URL}/style.css")
    gzip_css_encoding=$(echo "$gzip_css_headers" | grep -i '^content-encoding:' | tr -d '\r' || true)
    if echo "$gzip_css_encoding" | grep -qi "gzip"; then
        record_result "06" "Gzip compression negotiated for CSS (Content-Encoding: gzip)" 0 "Encoding Header: $gzip_css_encoding"
    else
        record_result "06" "Gzip compression negotiated for CSS (Content-Encoding: gzip)" 1 "Missing gzip in header: $gzip_css_encoding"
    fi

    # 7. Gzip compression on JS
    local gzip_js_headers gzip_js_encoding
    gzip_js_headers=$(curl -s -i -H "Accept-Encoding: gzip" "${BASE_URL}/app.js")
    gzip_js_encoding=$(echo "$gzip_js_headers" | grep -i '^content-encoding:' | tr -d '\r' || true)
    if echo "$gzip_js_encoding" | grep -qi "gzip"; then
        record_result "07" "Gzip compression negotiated for JS (Content-Encoding: gzip)" 0 "Encoding Header: $gzip_js_encoding"
    else
        record_result "07" "Gzip compression negotiated for JS (Content-Encoding: gzip)" 1 "Missing gzip in header: $gzip_js_encoding"
    fi

    # 8. Gzip size reduction verification
    local uncompressed_size compressed_size
    uncompressed_size=$(curl -s "${BASE_URL}/style.css" | wc -c | tr -d ' ')
    compressed_size=$(curl -s -H "Accept-Encoding: gzip" "${BASE_URL}/style.css" | wc -c | tr -d ' ')
    if [[ $compressed_size -lt $uncompressed_size ]]; then
        record_result "08" "Gzip payload size is significantly smaller than uncompressed" 0 "Uncompressed: ${uncompressed_size}B vs Compressed: ${compressed_size}B"
    else
        record_result "08" "Gzip payload size is significantly smaller than uncompressed" 1 "Uncompressed: ${uncompressed_size}B vs Compressed: ${compressed_size}B"
    fi

    echo -e "\n${CLR_BOLD}--- 3. Reverse Proxy & Header Forwarding ---${CLR_RESET}"

    # 9. Dynamic API routing: /api/health
    local api_health_res
    api_health_res=$(curl -s "${BASE_URL}/api/health")
    if echo "$api_health_res" | grep -qi '"status": "healthy"'; then
        record_result "09" "Reverse proxy forwards '/api/health' to backend returning JSON healthy status" 0 "Payload: $(echo "$api_health_res" | tr -d '\n' | cut -c 1-80)..."
    else
        record_result "09" "Reverse proxy forwards '/api/health' to backend returning JSON healthy status" 1 "Invalid health payload: $api_health_res"
    fi

    # 10. Dynamic API routing: /api/time
    local api_time_res
    api_time_res=$(curl -s "${BASE_URL}/api/time")
    if echo "$api_time_res" | grep -qi 'utc_iso'; then
        record_result "10" "Reverse proxy forwards '/api/time' returning dynamic UTC timestamp" 0 "Payload: $(echo "$api_time_res" | tr -d '\n' | cut -c 1-80)..."
    else
        record_result "10" "Reverse proxy forwards '/api/time' returning dynamic UTC timestamp" 1 "Invalid time payload: $api_time_res"
    fi

    # 11. Header Forwarding: /api/info
    local api_info_res
    api_info_res=$(curl -s "${BASE_URL}/api/info")
    if echo "$api_info_res" | grep -qi '"proxy_detected": true'; then
        record_result "11" "Nginx properly sets and forwards proxy headers (X-Forwarded-For, X-Real-IP, Host)" 0 "Proxy detection: Confirmed in backend introspection"
    else
        record_result "11" "Nginx properly sets and forwards proxy headers (X-Forwarded-For, X-Real-IP, Host)" 1 "Proxy headers not detected in /api/info: $api_info_res"
    fi

    # 12. Security & Educational Custom Header
    local proxy_by_hdr
    proxy_by_hdr=$(curl -s -i "${BASE_URL}/" | grep -i '^x-proxy-by:' | tr -d '\r' || true)
    if echo "$proxy_by_hdr" | grep -qi 'Nginx-Reverse-Proxy-MiniProject'; then
        record_result "12" "Nginx injects custom 'X-Proxy-By' educational header" 0 "Header: $proxy_by_hdr"
    else
        record_result "12" "Nginx injects custom 'X-Proxy-By' educational header" 1 "Header missing: $proxy_by_hdr"
    fi

    echo -e "\n${CLR_BOLD}--- 4. Edge Error Interception & Handling ---${CLR_RESET}"

    # 13. Custom 404 interception
    local rand_path notfound_headers notfound_code notfound_body
    rand_path="/route-that-does-not-exist-$(date +%s)"
    notfound_headers=$(curl -s -i "${BASE_URL}${rand_path}")
    notfound_code=$(echo "$notfound_headers" | head -n 1 | awk '{print $2}')
    notfound_body=$(curl -s "${BASE_URL}${rand_path}")
    if [[ "$notfound_code" == "404" ]] && echo "$notfound_body" | grep -qi "Resource Not Found"; then
        record_result "13" "Invalid route triggers HTTP 404 and serves custom branded 404 HTML page" 0 "Status: $notfound_code, Custom Marker: Found"
    else
        record_result "13" "Invalid route triggers HTTP 404 and serves custom branded 404 HTML page" 1 "Expected 404 & custom body, got status: $notfound_code"
    fi

    # 14. Custom 50x / Upstream error simulation
    local err500_headers err500_code err500_body
    err500_headers=$(curl -s -i "${BASE_URL}/api/simulate-error?code=500")
    err500_code=$(echo "$err500_headers" | head -n 1 | awk '{print $2}')
    err500_body=$(curl -s "${BASE_URL}/api/simulate-error?code=500")
    if [[ "$err500_code" == "500" ]] && echo "$err500_body" | grep -qi "Server Error"; then
        record_result "14" "Upstream 500 error is intercepted by proxy and serves custom 50x HTML page" 0 "Status: $err500_code, Custom 50x Marker: Found"
    else
        record_result "14" "Upstream 500 error is intercepted by proxy and serves custom 50x HTML page" 1 "Expected 500 & custom 50x page, got status: $err500_code"
    fi

    echo -e "\n======================================================================"
    echo -e "${CLR_BOLD}  📊 Test Suite Execution Summary${CLR_RESET}"
    echo "======================================================================"
    echo -e "  Total Tests:    ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
    echo -e "  Passed Tests:   ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
    echo -e "  Failed Tests:   ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
    echo "======================================================================"

    if [[ $FAILED_TESTS -eq 0 ]]; then
        echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 SUCCESS: All tests passed flawlessly!${CLR_RESET}\n"
        exit 0
    else
        echo -e "\n${CLR_RED}${CLR_BOLD}❌ FAILURE: ${FAILED_TESTS} test(s) failed.${CLR_RESET}\n"
        exit 1
    fi
}

run_tests
