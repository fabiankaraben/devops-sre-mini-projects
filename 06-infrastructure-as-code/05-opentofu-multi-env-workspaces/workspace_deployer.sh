#!/usr/bin/env bash
# ==============================================================================
# workspace_deployer.sh - OpenTofu Multi-Environment Workspace Manager
# ==============================================================================
# Automates workspace switching, variable file validation, planning, and deployment.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Detect IaC engine (tofu preferred, fallback to terraform)
IAC_BIN="tofu"
if ! command -v "$IAC_BIN" >/dev/null 2>&1; then
    if command -v terraform >/dev/null 2>&1; then
        IAC_BIN="terraform"
    else
        echo -e "${CLR_RED}Error: Neither 'tofu' nor 'terraform' found in PATH.${CLR_RESET}" >&2
        exit 1
    fi
fi

# Override engine via flag if provided
for arg in "$@"; do
    case "$arg" in
        --engine=*)
            IAC_BIN="${arg#*=}"
            ;;
    esac
done

usage() {
    echo -e "${CLR_BOLD}Usage:${CLR_RESET} ./workspace_deployer.sh [COMMAND] [ENVIRONMENT] [OPTIONS]"
    echo ""
    echo -e "${CLR_BOLD}Commands:${CLR_RESET}"
    echo "  list                     List all existing workspaces and show active workspace"
    echo "  select <env>             Switch to (or create) the specified workspace (dev, staging, prod)"
    echo "  plan <env>               Generate speculative execution plan using environments/<env>.tfvars"
    echo "  apply <env>              Apply infrastructure changes to the specified workspace"
    echo "  destroy <env>            Destroy infrastructure in the specified workspace"
    echo "  diff                     Compare sizing and resource allocations across dev, staging, prod"
    echo ""
    echo -e "${CLR_BOLD}Options:${CLR_RESET}"
    echo "  --engine=<tofu|terraform> Explicitly specify IaC binary (default: auto-detected)"
    echo "  --help, -h               Show this help message"
    echo ""
    echo -e "${CLR_BOLD}Examples:${CLR_RESET}"
    echo "  ./workspace_deployer.sh select dev"
    echo "  ./workspace_deployer.sh plan prod"
    echo "  ./workspace_deployer.sh apply staging"
    echo "  ./workspace_deployer.sh diff"
}

validate_env() {
    local env="$1"
    if [[ ! "$env" =~ ^(dev|staging|prod)$ ]]; then
        echo -e "${CLR_RED}Error: Invalid environment '$env'. Must be one of: dev, staging, prod${CLR_RESET}" >&2
        exit 1
    fi

    if [[ ! -f "environments/${env}.tfvars" ]]; then
        echo -e "${CLR_RED}Error: Variable file 'environments/${env}.tfvars' not found.${CLR_RESET}" >&2
        exit 1
    fi
}

cmd_list() {
    echo -e "${CLR_CYAN}${CLR_BOLD}▶ Listing OpenTofu Workspaces:${CLR_RESET}"
    "$IAC_BIN" workspace list
}

cmd_select() {
    local env="$1"
    validate_env "$env"
    echo -e "${CLR_CYAN}${CLR_BOLD}▶ Selecting/Creating Workspace: ${CLR_GREEN}${env}${CLR_RESET}"
    "$IAC_BIN" workspace select "$env" 2>/dev/null || "$IAC_BIN" workspace new "$env"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Active workspace is now: ${CLR_BOLD}$("$IAC_BIN" workspace show)${CLR_RESET}"
}

cmd_plan() {
    local env="$1"
    validate_env "$env"
    cmd_select "$env"
    echo -e "\n${CLR_CYAN}${CLR_BOLD}▶ Generating Plan for ${CLR_GREEN}${env}${CLR_CYAN} (environments/${env}.tfvars)...${CLR_RESET}"
    "$IAC_BIN" plan -var-file="environments/${env}.tfvars" -out="${env}-plan.tfplan"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Plan saved to: ${CLR_BOLD}${env}-plan.tfplan${CLR_RESET}"
}

cmd_apply() {
    local env="$1"
    validate_env "$env"
    cmd_select "$env"
    echo -e "\n${CLR_CYAN}${CLR_BOLD}▶ Applying Infrastructure to ${CLR_GREEN}${env}${CLR_CYAN}...${CLR_RESET}"
    "$IAC_BIN" apply -var-file="environments/${env}.tfvars" -auto-approve
    echo -e "\n  [${CLR_GREEN}OK${CLR_RESET}] Deployment complete for workspace: ${CLR_BOLD}${env}${CLR_RESET}"
}

cmd_destroy() {
    local env="$1"
    validate_env "$env"
    cmd_select "$env"
    echo -e "\n${CLR_YELLOW}${CLR_BOLD}▶ Destroying Infrastructure in Workspace: ${CLR_RED}${env}${CLR_YELLOW}...${CLR_RESET}"
    "$IAC_BIN" destroy -var-file="environments/${env}.tfvars" -auto-approve
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Destruction complete for workspace: ${CLR_BOLD}${env}${CLR_RESET}"
}

cmd_diff() {
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Multi-Environment Specification Matrix Comparison${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    printf "%-12s | %-12s | %-14s | %-18s | %-16s | %-20s\n" "Environment" "Instance" "Replicas" "Log Retention" "Backup Retention" "Deletion Protection"
    echo "-------------------------------------------------------------------------------------------------------"
    for env in dev staging prod; do
        inst=$(grep "instance_type" "environments/${env}.tfvars" | head -n 1 | awk -F'"' '{print $2}')
        count=$(grep "instance_count" "environments/${env}.tfvars" | head -n 1 | awk '{print $3}')
        logs=$(grep "log_retention_days" "environments/${env}.tfvars" | head -n 1 | awk '{print $3}')
        backup=$(grep "backup_retention_days" "environments/${env}.tfvars" | head -n 1 | awk '{print $3}')
        delprot=$(grep "enable_deletion_protection" "environments/${env}.tfvars" | head -n 1 | awk '{print $3}')
        printf "%-12s | %-12s | %-14s | %-18s | %-16s | %-20s\n" "$env" "$inst" "$count" "${logs} days" "${backup} days" "$delprot"
    done
    echo "======================================================================================================="
}

# Main command dispatch
COMMAND="${1:-}"
case "$COMMAND" in
    list)
        cmd_list
        ;;
    select)
        if [[ -z "${2:-}" ]]; then
            echo -e "${CLR_RED}Error: Missing environment argument.${CLR_RESET}" >&2
            usage
            exit 1
        fi
        cmd_select "$2"
        ;;
    plan)
        if [[ -z "${2:-}" ]]; then
            echo -e "${CLR_RED}Error: Missing environment argument.${CLR_RESET}" >&2
            usage
            exit 1
        fi
        cmd_plan "$2"
        ;;
    apply)
        if [[ -z "${2:-}" ]]; then
            echo -e "${CLR_RED}Error: Missing environment argument.${CLR_RESET}" >&2
            usage
            exit 1
        fi
        cmd_apply "$2"
        ;;
    destroy)
        if [[ -z "${2:-}" ]]; then
            echo -e "${CLR_RED}Error: Missing environment argument.${CLR_RESET}" >&2
            usage
            exit 1
        fi
        cmd_destroy "$2"
        ;;
    diff)
        cmd_diff
        ;;
    --help|-h|"")
        usage
        ;;
    *)
        echo -e "${CLR_RED}Error: Unknown command '$COMMAND'.${CLR_RESET}" >&2
        usage
        exit 1
        ;;
esac
