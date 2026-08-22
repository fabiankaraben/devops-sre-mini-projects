#!/usr/bin/env bash
# ==============================================================================
# test_static_hosting.sh - Automated Static Web Hosting & CDN Test Runner
# ==============================================================================
# Validates HTML/CSS/JS web assets, CloudFront function syntax, Terraform IaC
# configuration, and runs the CDN security audit test suite.
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERBOSE=false
RUN_LIVE=false

for arg in "$@"; do
    case "$arg" in
        --live)
            RUN_LIVE=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: ./test_static_hosting.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --live         Run tests against live AWS CloudFront distribution from Terraform output"
            echo "  --verbose, -v  Show detailed diagnostic logs during test run"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./test_static_hosting.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ S3 + CloudFront Secure Static Web Hosting Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Check Tooling Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Checking Tooling Prerequisites...${CLR_RESET}"

if ! command -v curl >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] curl is required but not found."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] curl is available."

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] python3 is required for mock server testing."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] python3 is available ($(python3 --version))."

IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

if [[ -n "$IAC_BIN" ]]; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC Engine: $IAC_BIN ($($IAC_BIN version -json 2>/dev/null | grep -o '"version":"[^"]*"' || $IAC_BIN --version | head -n 1))"
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Neither Terraform nor OpenTofu found in PATH."
fi

# ------------------------------------------------------------------------------
# 2. Validate Static Web Application Assets
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Validating Static Web Application Assets...${CLR_RESET}"

REQUIRED_FILES=("website/index.html" "website/error.html" "website/css/styles.css" "website/js/app.js" "functions/security-headers.js")
MISSING_FILES=0

for file in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$SCRIPT_DIR/$file" ]]; then
        if [[ "$VERBOSE" == true ]]; then
            echo -e "  [${CLR_GREEN}FOUND${CLR_RESET}] $file ($(wc -c < "$SCRIPT_DIR/$file" | tr -d ' ') bytes)"
        fi
    else
        echo -e "  [${CLR_RED}MISSING${CLR_RESET}] $file"
        MISSING_FILES=$((MISSING_FILES + 1))
    fi
done

if [[ $MISSING_FILES -gt 0 ]]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Found $MISSING_FILES missing required web asset files."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All static web application files are present and verified."

# Check CloudFront function syntax with node if available
if command -v node >/dev/null 2>&1; then
    if node --check "$SCRIPT_DIR/functions/security-headers.js" >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] CloudFront Function JavaScript syntax validated."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] CloudFront Function syntax error."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 3. Validate Terraform IaC Manifests
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Validating Terraform / OpenTofu Manifests...${CLR_RESET}"
if [[ -n "$IAC_BIN" ]]; then
    echo "  Checking IaC code formatting..."
    if "$IAC_BIN" fmt -check "$SCRIPT_DIR" >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC files properly formatted."
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Reformatting IaC manifests..."
        "$IAC_BIN" fmt "$SCRIPT_DIR"
    fi

    echo "  Initializing and validating IaC syntax..."
    "$IAC_BIN" init -backend=false -input=false >/dev/null 2>&1 || true
    if "$IAC_BIN" validate >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC configuration is structurally valid."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] IaC validation failed. Run '$IAC_BIN validate' for details."
        "$IAC_BIN" validate
        exit 1
    fi
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] IaC validator skipped (no binary found)."
fi

# ------------------------------------------------------------------------------
# 4. Execute CDN Security Audit
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing CDN Security & Origin Access Audit...${CLR_RESET}"

AUDIT_ARGS=("--json-output" "$SCRIPT_DIR/test_report.json")
if [[ "$VERBOSE" == true ]]; then
    AUDIT_ARGS+=("--verbose")
fi

if [[ "$RUN_LIVE" == true ]]; then
    echo "  Running audit against LIVE CloudFront distribution..."
else
    AUDIT_ARGS+=("--mock")
    echo "  Running audit in LOCAL OFFLINE MOCK mode..."
fi

if "$SCRIPT_DIR/verify_cdn_security.sh" "${AUDIT_ARGS[@]}"; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 All Static Hosting & CDN Security Tests Passed Successfully!${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_RED}${CLR_BOLD}  ❌ CDN Security Audit Failed! Review findings above.${CLR_RESET}"
    echo -e "${CLR_RED}${CLR_BOLD}======================================================================${CLR_RESET}\n"
    exit 1
fi
