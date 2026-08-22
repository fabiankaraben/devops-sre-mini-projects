#!/usr/bin/env bash
# ==============================================================================
# test_serverless_pipeline.sh - Automated Serverless SQS & Lambda Test Runner
# ==============================================================================
# Validates Python Lambda handler syntax, Terraform IaC configuration, and executes
# the end-to-end event-driven message pipeline test suite.
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
TOTAL_MSG=100
POISON_MSG=20

for arg in "$@"; do
    case "$arg" in
        --live)
            RUN_LIVE=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --total=*)
            TOTAL_MSG="${arg#*=}"
            ;;
        --poison=*)
            POISON_MSG="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./test_serverless_pipeline.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --live         Publish to live AWS SQS queue from Terraform outputs"
            echo "  --total=INT    Total test messages to generate (default: 100)"
            echo "  --poison=INT   Number of poison pill messages (default: 20)"
            echo "  --verbose, -v  Show detailed retry and batch logs"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./test_serverless_pipeline.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ AWS Lambda + SQS FIFO Event-Driven Pipeline Test Runner"
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
# 2. Validate Lambda Handler Code Syntax
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Validating Python Lambda Code Syntax...${CLR_RESET}"

python3 -m py_compile "$SCRIPT_DIR/lambda/index.py"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] lambda/index.py syntax valid."

python3 -m py_compile "$SCRIPT_DIR/message_producer.py"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] message_producer.py syntax valid."

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
# 4. Execute Pipeline Test Engine (100 Messages Workload)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Serverless Pipeline Test Engine...${CLR_RESET}"

PRODUCER_ARGS=("--total" "$TOTAL_MSG" "--poison-count" "$POISON_MSG" "--json-output" "$SCRIPT_DIR/test_report.json")
if [[ "$VERBOSE" == true ]]; then
    PRODUCER_ARGS+=("--verbose")
fi

if [[ "$RUN_LIVE" == true ]]; then
    if [[ -f "$SCRIPT_DIR/terraform.tfstate" ]]; then
        Q_URL=$(terraform output -raw primary_queue_url 2>/dev/null || true)
        DLQ_URL=$(terraform output -raw dlq_url 2>/dev/null || true)
        PRODUCER_ARGS+=("--mode" "aws" "--queue-url" "$Q_URL" "--dlq-url" "$DLQ_URL")
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Cannot run live test: terraform.tfstate not found. Run 'terraform apply' first."
        exit 1
    fi
else
    PRODUCER_ARGS+=("--mode" "offline")
fi

if python3 "$SCRIPT_DIR/message_producer.py" "${PRODUCER_ARGS[@]}"; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 All Serverless Pipeline & DLQ Tests Passed Successfully!${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_RED}${CLR_BOLD}  ❌ Serverless Pipeline Test Failed! Review findings above.${CLR_RESET}"
    echo -e "${CLR_RED}${CLR_BOLD}======================================================================${CLR_RESET}\n"
    exit 1
fi
