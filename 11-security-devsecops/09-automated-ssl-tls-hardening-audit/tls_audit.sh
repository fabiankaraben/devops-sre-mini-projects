#!/usr/bin/env bash
# ==============================================================================
# tls_audit.sh - Automated SSL/TLS Cipher Hardening CLI Audit Runner
# ==============================================================================
# Audits target HTTPS endpoints for weak ciphers, deprecated TLS versions (1.0/1.1),
# certificate validity, and HTTP security headers (HSTS, etc.).
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGETS=("localhost:8443" "localhost:9443")
CA_FILE="$SCRIPT_DIR/certs/ca.crt"
REPORTS_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORTS_DIR"

print_usage() {
    echo -e "${CLR_CYAN}Usage: ./tls_audit.sh [OPTIONS] [TARGETS...]${CLR_RESET}"
    echo ""
    echo "Options:"
    echo "  --ca-file <PATH>       Path to local CA certificate (default: certs/ca.crt)"
    echo "  --reports-dir <DIR>    Reports output directory (default: reports/)"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./tls_audit.sh"
    echo "  ./tls_audit.sh localhost:8443 localhost:9443"
    echo "  ./tls_audit.sh --ca-file certs/ca.crt 127.0.0.1:9443"
}

CUSTOM_TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ca-file)
            CA_FILE="$2"
            shift 2
            ;;
        --reports-dir)
            REPORTS_DIR="$2"
            shift 2
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        -*)
            echo -e "${CLR_RED}Error: Unknown option '$1'${CLR_RESET}"
            print_usage
            exit 1
            ;;
        *)
            CUSTOM_TARGETS+=("$1")
            shift
            ;;
    esac
done

if [ ${#CUSTOM_TARGETS[@]} -gt 0 ]; then
    TARGETS=("${CUSTOM_TARGETS[@]}")
fi

# Ensure certificates exist
if [ ! -f "$CA_FILE" ] || [ ! -f "$SCRIPT_DIR/certs/server.crt" ]; then
    echo -e "${CLR_YELLOW}▶ Generating required TLS certificates...${CLR_RESET}"
    ./generate_certificates.sh >/dev/null 2>&1
fi

# Ensure mock containers are running if auditing localhost default ports
if [[ "${TARGETS[*]}" =~ "8443" ]] || [[ "${TARGETS[*]}" =~ "9443" ]]; then
    if ! docker ps --format '{{.Names}}' | grep -q "hardened-tls-server"; then
        echo -e "${CLR_YELLOW}▶ Starting mock Nginx TLS endpoints (weak on :8443, hardened on :9443)...${CLR_RESET}"
        docker compose up -d >/dev/null 2>&1
        sleep 2
    fi
fi

# Execute Python TLS audit prober
python3 "$SCRIPT_DIR/tls_audit.py" \
    --targets "${TARGETS[@]}" \
    --ca-file "$CA_FILE" \
    --json-out "$REPORTS_DIR/tls_audit_report.json" \
    --md-out "$REPORTS_DIR/tls_audit_report.md" \
    --html-out "$REPORTS_DIR/tls_audit_report.html"
