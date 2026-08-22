#!/usr/bin/env bash
# ==============================================================================
# verify_cdn_security.sh - Automated CDN Security & Origin Access Audit
# ==============================================================================
# Audits CloudFront edge responses for HTTPS enforcement, 7 essential HTTP
# security headers, S3 Origin Access Control (OAC) 403 blocking, and 404 routing.
#
# Supports:
#   1. Live AWS CloudFront & S3 endpoints
#   2. 100% Local Mock Server for offline testing and CI/CD pipelines
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET_URL=""
S3_URL=""
MOCK_MODE=false
VERBOSE=false
JSON_OUT=""
MOCK_PORT=8443
MOCK_PID=""

cleanup_mock() {
    if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" >/dev/null 2>&1; then
        kill "$MOCK_PID" >/dev/null 2>&1 || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
}
trap cleanup_mock EXIT INT TERM

show_help() {
    echo "Usage: ./verify_cdn_security.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --url URL         CloudFront CDN HTTPS URL to test (e.g. https://d123.cloudfront.net)"
    echo "  --s3-url URL      Direct S3 Endpoint URL to assert 403 Forbidden"
    echo "  --mock, --offline Run against local mock HTTP server (100% offline, zero cloud needed)"
    echo "  --json-output FILE Write audit results to structured JSON report"
    echo "  --verbose, -v     Show full response headers and detailed evaluation logs"
    echo "  --help, -h        Show this help message"
}

for arg in "$@"; do
    case "$arg" in
        --url=*)
            TARGET_URL="${arg#*=}"
            ;;
        --s3-url=*)
            S3_URL="${arg#*=}"
            ;;
        --json-output=*)
            JSON_OUT="${arg#*=}"
            ;;
        --mock|--offline)
            MOCK_MODE=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac
done

# Handle space-separated arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            TARGET_URL="$2"
            shift 2
            ;;
        --s3-url)
            S3_URL="$2"
            shift 2
            ;;
        --json-output)
            JSON_OUT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Auto-detect target URLs from Terraform outputs if not provided
if [[ -z "$TARGET_URL" ]] && [[ "$MOCK_MODE" == false ]]; then
    if [[ -f "$SCRIPT_DIR/terraform.tfstate" ]]; then
        TARGET_URL=$(terraform output -raw cloudfront_url 2>/dev/null || true)
        S3_URL=$(terraform output -raw s3_direct_url 2>/dev/null || true)
    fi
fi

if [[ -z "$TARGET_URL" ]] && [[ "$MOCK_MODE" == false ]]; then
    echo -e "${CLR_YELLOW}[INFO] No live CloudFront URL specified. Defaulting to --mock mode.${CLR_RESET}"
    MOCK_MODE=true
fi

# ------------------------------------------------------------------------------
# Launch Local Mock Server in Mock Mode
# ------------------------------------------------------------------------------
if [[ "$MOCK_MODE" == true ]]; then
    echo -e "${CLR_CYAN}▶ Starting Local CloudFront & S3 Mock Audit Server on port ${MOCK_PORT}...${CLR_RESET}"
    python3 - << 'EOF' &
import sys
import http.server
import socketserver

PORT = 8443

class MockCDNHandler(http.server.BaseHTTPRequestHandler):
    def send_security_headers(self, status=200, content_type='text/html; charset=utf-8', cache_control='max-age=0, must-revalidate'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', cache_control)
        self.send_header('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-XSS-Protection', '1; mode=block')
        self.send_header('Referrer-Policy', 'strict-origin-when-cross-origin')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;")
        self.send_header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
        self.send_header('Server', 'CloudFront')
        self.send_header('Via', '1.1 mock.cloudfront.net (CloudFront)')
        self.end_headers()

    def do_HEAD(self):
        self._handle_request(send_body=False)

    def do_GET(self):
        self._handle_request(send_body=True)

    def _handle_request(self, send_body=True):
        # Direct S3 Access Simulation -> Return 403 Forbidden
        if ('Host' in self.headers and 's3.amazonaws.com' in self.headers['Host']) or self.path.startswith('/direct-s3-test'):
            self.send_response(403)
            self.send_header('Content-Type', 'application/xml')
            self.send_header('Server', 'AmazonS3')
            self.end_headers()
            if send_body:
                self.wfile.write(b'<Error><Code>AccessDenied</Code><Message>Access Denied. Only CloudFront OAC allowed.</Message></Error>')
            return

        # Static assets
        if self.path.startswith('/css/') or self.path.startswith('/js/'):
            ct = 'text/css' if self.path.endswith('.css') else 'application/javascript'
            self.send_security_headers(200, ct, 'max-age=31536000, immutable')
            if send_body:
                self.wfile.write(b'/* Asset Content */')
            return

        # Root HTML
        if self.path in ('/', '/index.html'):
            self.send_security_headers(200, 'text/html; charset=utf-8', 'max-age=0, must-revalidate')
            if send_body:
                self.wfile.write(b'<!DOCTYPE html><html><body><h1>CloudEdge CDN</h1></body></html>')
            return

        # 404 Custom Error Page
        self.send_security_headers(404, 'text/html; charset=utf-8', 'max-age=10')
        if send_body:
            self.wfile.write(b'<!DOCTYPE html><html><body><h1>404 Resource Not Found</h1></body></html>')

    def log_message(self, format, *args):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), MockCDNHandler) as httpd:
    httpd.serve_forever()
EOF
    MOCK_PID=$!
    sleep 0.5

    TARGET_URL="http://127.0.0.1:${MOCK_PORT}"
    S3_URL="http://127.0.0.1:${MOCK_PORT}/direct-s3-test"
fi

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🛡️  AWS CloudFront CDN & S3 Origin Security Audit Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e "  Target CDN URL : ${CLR_WHITE}${TARGET_URL}${CLR_RESET}"
echo -e "  S3 Direct URL  : ${CLR_WHITE}${S3_URL:-'N/A'}${CLR_RESET}"
echo -e "  Audit Mode     : ${CLR_MAGENTA}$([[ "$MOCK_MODE" == true ]] && echo "LOCAL MOCK (OFFLINE)" || echo "LIVE AWS CLOUD")${CLR_RESET}\n"

# ------------------------------------------------------------------------------
# Audit Metrics
# ------------------------------------------------------------------------------
PASSED=0
FAILED=0
TOTAL=0

assert_check() {
    local check_id="$1"
    local description="$2"
    local expected="$3"
    local actual="$4"
    local pass_condition="$5"

    TOTAL=$((TOTAL + 1))
    local is_pass=false

    if eval "$pass_condition"; then
        is_pass=true
        PASSED=$((PASSED + 1))
        printf "${CLR_WHITE}%-8s${CLR_RESET} %-52s [${CLR_GREEN}PASS${CLR_RESET}]\n" "$check_id" "$description"
    else
        FAILED=$((FAILED + 1))
        printf "${CLR_WHITE}%-8s${CLR_RESET} %-52s [${CLR_RED}FAIL${CLR_RESET}]\n" "$check_id" "$description"
        echo -e "  ${CLR_GRAY}↳ Expected: ${expected}${CLR_RESET}"
        echo -e "  ${CLR_GRAY}↳ Actual  : ${actual}${CLR_RESET}"
    fi
}

echo -e "${CLR_YELLOW}▶ [Phase 1] CloudFront Edge Connectivity & Status Code Checks${CLR_RESET}"
echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

# Fetch Root Headers
RESPONSE_HEADERS=$(curl -s -I -L "$TARGET_URL/" 2>/dev/null || echo "")
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL/" 2>/dev/null || echo "000")

if [[ "$VERBOSE" == true ]]; then
    echo -e "${CLR_GRAY}--- Full Response Headers ---${CLR_RESET}"
    echo "$RESPONSE_HEADERS"
    echo -e "${CLR_GRAY}-----------------------------${CLR_RESET}"
fi

assert_check "CDN-01" "Root URL returns HTTP 200 OK" "200" "$HTTP_STATUS" '[[ "$HTTP_STATUS" == "200" ]]'

# Check 404 Custom Error Routing
HTTP_404_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL/non-existent-page-xyz" 2>/dev/null || echo "000")
assert_check "CDN-02" "Non-existent path returns HTTP 404" "404" "$HTTP_404_STATUS" '[[ "$HTTP_404_STATUS" == "404" ]]'

echo -e "\n${CLR_YELLOW}▶ [Phase 2] Origin Access Control (OAC) S3 Isolation Checks${CLR_RESET}"
echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

if [[ -n "$S3_URL" ]]; then
    S3_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$S3_URL" 2>/dev/null || echo "000")
    assert_check "OAC-01" "Direct S3 access is blocked with 403 Forbidden" "403" "$S3_STATUS" '[[ "$S3_STATUS" == "403" ]]'
else
    echo -e "  ${CLR_GRAY}[SKIP] No direct S3 URL provided. Skipping OAC-01.${CLR_RESET}"
fi

echo -e "\n${CLR_YELLOW}▶ [Phase 3] HTTP Security Headers Verification (OWASP Standards)${CLR_RESET}"
echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

get_header() {
    local header_name="$1"
    echo "$RESPONSE_HEADERS" | grep -i "^${header_name}:" | tr -d '\r' | head -n 1 | sed -e "s/^${header_name}:[[:space:]]*//I" || echo ""
}

# 1. Strict-Transport-Security (HSTS)
HSTS_VAL=$(get_header "Strict-Transport-Security")
assert_check "SEC-01" "Strict-Transport-Security (HSTS) enforced" "max-age >= 31536000" "$HSTS_VAL" '[[ "$HSTS_VAL" =~ max-age && "$HSTS_VAL" =~ includeSubDomains ]]'

# 2. X-Frame-Options
XFO_VAL=$(get_header "X-Frame-Options")
assert_check "SEC-02" "X-Frame-Options set to DENY/SAMEORIGIN (Anti-Clickjacking)" "DENY" "$XFO_VAL" '[[ "$XFO_VAL" =~ ^(DENY|SAMEORIGIN)$ ]]'

# 3. X-Content-Type-Options
XCTO_VAL=$(get_header "X-Content-Type-Options")
assert_check "SEC-03" "X-Content-Type-Options set to nosniff" "nosniff" "$XCTO_VAL" '[[ "$XCTO_VAL" == "nosniff" ]]'

# 4. Content-Security-Policy (CSP)
CSP_VAL=$(get_header "Content-Security-Policy")
assert_check "SEC-04" "Content-Security-Policy restricts default-src" "default-src 'self'" "$CSP_VAL" '[[ "$CSP_VAL" =~ default-src ]]'

# 5. Referrer-Policy
RP_VAL=$(get_header "Referrer-Policy")
assert_check "SEC-05" "Referrer-Policy configured" "strict-origin-when-cross-origin" "$RP_VAL" '[[ -n "$RP_VAL" ]]'

# 6. Permissions-Policy
PP_VAL=$(get_header "Permissions-Policy")
assert_check "SEC-06" "Permissions-Policy restricts sensitive hardware APIs" "camera=(), microphone=()" "$PP_VAL" '[[ -n "$PP_VAL" ]]'

# 7. X-XSS-Protection
XXSS_VAL=$(get_header "X-XSS-Protection")
assert_check "SEC-07" "X-XSS-Protection configured" "1; mode=block" "$XXSS_VAL" '[[ "$XXSS_VAL" =~ "1" ]]'

echo -e "\n${CLR_YELLOW}▶ [Phase 4] Caching & Performance Headers Verification${CLR_RESET}"
echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

CC_VAL=$(get_header "Cache-Control")
assert_check "PRF-01" "HTML Cache-Control prevents stale SPA caching" "max-age=0 / must-revalidate" "$CC_VAL" '[[ "$CC_VAL" =~ (max-age=0|must-revalidate|no-cache) ]]'

# ------------------------------------------------------------------------------
# Final Summary
# ------------------------------------------------------------------------------
PASS_PCT=0
if [[ $TOTAL -gt 0 ]]; then
    PASS_PCT=$(( (PASSED * 100) / TOTAL ))
fi

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  ${CLR_BOLD}Security Audit Summary:${CLR_RESET}"
echo -e "  Total Checks   : ${CLR_WHITE}${TOTAL}${CLR_RESET}"
echo -e "  Passed         : ${CLR_GREEN}${PASSED}${CLR_RESET}"
echo -e "  Failed         : $([[ $FAILED -gt 0 ]] && echo "${CLR_RED}${FAILED}" || echo "${CLR_GREEN}0")${CLR_RESET}"
echo -e "  Compliance Score: $([[ $PASS_PCT -eq 100 ]] && echo "${CLR_GREEN}${PASS_PCT}%" || echo "${CLR_YELLOW}${PASS_PCT}%")${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

if [[ -n "$JSON_OUT" ]]; then
    cat << EOF > "$JSON_OUT"
{
  "target_url": "$TARGET_URL",
  "s3_url": "$S3_URL",
  "mode": "$([[ "$MOCK_MODE" == true ]] && echo "mock" || echo "live")",
  "total_checks": $TOTAL,
  "passed": $PASSED,
  "failed": $FAILED,
  "compliance_percentage": $PASS_PCT,
  "headers": {
    "Strict-Transport-Security": "$HSTS_VAL",
    "X-Frame-Options": "$XFO_VAL",
    "X-Content-Type-Options": "$XCTO_VAL",
    "Content-Security-Policy": "$CSP_VAL",
    "Referrer-Policy": "$RP_VAL",
    "Permissions-Policy": "$PP_VAL",
    "X-XSS-Protection": "$XXSS_VAL",
    "Cache-Control": "$CC_VAL"
  }
}
EOF
    echo -e "${CLR_GRAY}[INFO] JSON audit report exported to: ${JSON_OUT}${CLR_RESET}\n"
fi

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
