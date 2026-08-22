#!/usr/bin/env bash
# ==============================================================================
# validate_and_docs.sh - Automated IaC Linting & Documentation Generation
# ==============================================================================
# Executes:
#   1. Terraform / OpenTofu canonical format validation (`fmt -check`)
#   2. Static security and convention linting via `tflint --recursive`
#   3. Automated module schema documentation generation via `terraform-docs`
#   4. Syntactic and type validation across module and root environments
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
echo "  🔍 Validating Modular AWS VPC & Updating Module Documentation"
echo "======================================================================"
echo -e "${CLR_RESET}"

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

echo -e "${CLR_YELLOW}▶ [1/4] Checking HCL Code Formatting...${CLR_RESET}"
if "$IAC_BIN" fmt -check -recursive; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All HCL files match canonical formatting."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Formatting errors found. Run '$IAC_BIN fmt -recursive'."
    exit 1
fi

echo -e "\n${CLR_YELLOW}▶ [2/4] Running TFLint Static Analysis...${CLR_RESET}"
if command -v tflint >/dev/null 2>&1; then
    tflint --recursive
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] TFLint passed across all modules and environments."
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] tflint binary not found; skipping TFLint checks."
fi

echo -e "\n${CLR_YELLOW}▶ [3/4] Updating Module Documentation via terraform-docs...${CLR_RESET}"
if command -v terraform-docs >/dev/null 2>&1; then
    TEMP_DOCS=$(mktemp)
    cat << 'EOF' > "$TEMP_DOCS"
<!-- markdownlint-disable MD013 MD033 -->
# Reusable Modular AWS VPC Module

> Reusable Terraform & OpenTofu module provisioning a multi-tier, High-Availability AWS VPC across 2 or 3 Availability Zones.

---

## Architecture Overview

```text
               Internet Gateway (0.0.0.0/0)
                           │
       ┌───────────────────┼───────────────────┐
       ▼                   ▼                   ▼
Public Subnet 1     Public Subnet 2     Public Subnet 3
(10.0.1.0/24)       (10.0.2.0/24)       (10.0.3.0/24)
 [NAT Gateway 1]     [NAT Gateway 2]     [NAT Gateway 3]
       │                   │                   │
       ▼                   ▼                   ▼
Private Subnet 1    Private Subnet 2    Private Subnet 3
(10.0.11.0/24)      (10.0.12.0/24)      (10.0.13.0/24)
```

---

EOF
    terraform-docs markdown table modules/vpc >> "$TEMP_DOCS"
    mv "$TEMP_DOCS" modules/vpc/README.md
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Updated modules/vpc/README.md successfully."
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] terraform-docs not found; skipping doc generation."
fi

echo -e "\n${CLR_YELLOW}▶ [4/4] Validating Terraform Configurations...${CLR_RESET}"
for env_dir in "environments/dev" "environments/prod"; do
    echo "  Validating ${env_dir}..."
    (
        cd "$env_dir"
        "$IAC_BIN" init -backend=false -input=false >/dev/null 2>&1
        "$IAC_BIN" validate
    )
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] ${env_dir} configuration is valid."
done

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ VALIDATION & DOCUMENTATION COMPLETE: All checks passed.${CLR_RESET}\n"
