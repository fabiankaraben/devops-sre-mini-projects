#!/usr/bin/env bash
# ==============================================================================
# vpc_reachability_test.sh - Multi-VPC Network Reachability & Isolation Test
# ==============================================================================
# Verifies network connectivity between authorized subnets and confirms complete
# packet drops between isolated spoke environments (Prod <-> Staging).
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
JSON_OUT=""

for arg in "$@"; do
    case "$arg" in
        --verbose|-v)
            VERBOSE=true
            ;;
        --json-output=*)
            JSON_OUT="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./vpc_reachability_test.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v       Show granular packet tracer hops and routing tables"
            echo "  --json-output=FILE  Save structured JSON report"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./vpc_reachability_test.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🌐 AWS Multi-VPC Transit Gateway Reachability & Isolation Audit"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Execute Network Simulator
# ------------------------------------------------------------------------------
ARGS=()
if [[ "$VERBOSE" == true ]]; then
    ARGS+=("--verbose")
fi
if [[ -n "$JSON_OUT" ]]; then
    ARGS+=("--json-output" "$JSON_OUT")
fi

python3 "$SCRIPT_DIR/network_simulator.py" "${ARGS[@]}"
