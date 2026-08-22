#!/usr/bin/env bash
# ==============================================================================
# test_multi_vpc.sh - Multi-VPC Transit Gateway Test Runner
# ==============================================================================
# Validates Python syntax, Terraform IaC configuration, and executes the
# multi-VPC reachability and isolation test suite.
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

for arg in "$@"; do
    case "$arg" in
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: ./test_multi_vpc.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v  Show detailed packet tracer hops and routing tables"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./test_multi_vpc.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ AWS Multi-VPC Transit Gateway Pipeline Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Check Tooling Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Checking Tooling Prerequisites...${CLR_RESET}"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] python3 is required but not found in PATH."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found Python: $(python3 --version)"

IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

if [[ -n "$IAC_BIN" ]]; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found IaC Engine: $IAC_BIN ($($IAC_BIN version -json 2>/dev/null | grep -o '"version":"[^"]*"' || $IAC_BIN --version | head -n 1))"
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Neither Terraform nor OpenTofu found in PATH."
fi

# ------------------------------------------------------------------------------
# 2. Validate Python Script Syntax
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Validating Python Network Simulator Syntax...${CLR_RESET}"

python3 -m py_compile "$SCRIPT_DIR/network_simulator.py"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] network_simulator.py syntax valid."

# ------------------------------------------------------------------------------
# 3. Validate Terraform IaC Manifests
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Validating Terraform / OpenTofu Manifests...${CLR_RESET}"

if [[ -n "$IAC_BIN" ]]; then
    echo "  Checking IaC code formatting..."
    if "$IAC_BIN" fmt -check "$SCRIPT_DIR" >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC files properly formatted."
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Reformatting IaC files with '$IAC_BIN fmt'..."
        "$IAC_BIN" fmt "$SCRIPT_DIR"
    fi

    echo "  Initializing and validating IaC syntax..."
    "$IAC_BIN" init -backend=false -input=false >/dev/null 2>&1 || true
    if "$IAC_BIN" validate >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC configuration is structurally valid."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] IaC validation failed. Running '$IAC_BIN validate' for details:"
        "$IAC_BIN" validate
        exit 1
    fi
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] IaC validator skipped (no binary found)."
fi

# ------------------------------------------------------------------------------
# 4. Execute Reachability & Isolation Audit
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Multi-VPC Reachability & Isolation Tests...${CLR_RESET}"

AUDIT_ARGS=("--json-output" "$SCRIPT_DIR/test_report.json")
if [[ "$VERBOSE" == true ]]; then
    AUDIT_ARGS+=("--verbose")
fi

if python3 "$SCRIPT_DIR/network_simulator.py" "${AUDIT_ARGS[@]}"; then
    echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 All Multi-VPC Reachability & Isolation Tests Passed Successfully!${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
    exit 0
else
    echo -e "${CLR_RED}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_RED}${CLR_BOLD}  ❌ Multi-VPC Network Test Failed! Review findings above.${CLR_RESET}"
    echo -e "${CLR_RED}${CLR_BOLD}======================================================================${CLR_RESET}\n"
    exit 1
fi
