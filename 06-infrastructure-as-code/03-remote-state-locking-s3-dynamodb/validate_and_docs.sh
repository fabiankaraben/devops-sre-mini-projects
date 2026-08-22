#!/usr/bin/env bash
# ==============================================================================
# validate_and_docs.sh - Automated IaC Linting & Schema Validation
# ==============================================================================
# Executes:
#   1. Canonical format verification (`terraform fmt -check -recursive`)
#   2. Static security and convention linting via `tflint --recursive`
#   3. Syntactic and type validation across bootstrap and workload configs
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔍 Validating Remote State Locking Infrastructure (S3 & DynamoDB)"
echo "======================================================================"
echo -e "${CLR_RESET}"

# AWS dummy credentials for offline schema validation
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

# 1. Detect IaC engine (terraform or tofu)
IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
else
    echo -e "${CLR_RED}Error: Neither 'terraform' nor 'tofu' found in PATH.${CLR_RESET}"
    exit 1
fi

echo -e "${CLR_YELLOW}▶ [1/3] Checking HCL Code Formatting...${CLR_RESET}"
if "$IAC_BIN" fmt -check -recursive; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All HCL files match canonical formatting."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Formatting errors found. Run '$IAC_BIN fmt -recursive'."
    exit 1
fi

echo -e "\n${CLR_YELLOW}▶ [2/3] Running TFLint Static Analysis...${CLR_RESET}"
if command -v tflint >/dev/null 2>&1; then
    tflint --recursive
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] TFLint passed across all modules."
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] tflint binary not found; skipping TFLint checks."
fi

echo -e "\n${CLR_YELLOW}▶ [3/3] Validating Terraform Configurations...${CLR_RESET}"
for config_dir in "backend_bootstrap" "demo_infrastructure"; do
    echo "  Validating ${config_dir}..."
    (
        cd "$config_dir"
        rm -f .terraform/terraform.tfstate
        "$IAC_BIN" init -backend=false -reconfigure -input=false >/dev/null 2>&1
        "$IAC_BIN" validate
    )
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] ${config_dir} configuration is valid."
done

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ VALIDATION COMPLETE: All checks passed.${CLR_RESET}\n"
