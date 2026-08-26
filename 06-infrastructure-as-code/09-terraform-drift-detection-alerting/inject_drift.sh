#!/usr/bin/env bash
# ==============================================================================
# inject_drift.sh - Intentional Out-of-Band Cloud Drift Injector
# ==============================================================================
# Modifies cloud resources directly via the AWS API / CLI to simulate out-of-band
# configuration drift without updating Terraform code or state.
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"

AWS_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$AWS_REGION"

AWS_CLI="aws --endpoint-url=${AWS_ENDPOINT} --region=${AWS_REGION}"

SCENARIO="security-group"
RESTORE=false

for arg in "$@"; do
    case "$arg" in
        --scenario=*)
            SCENARIO="${arg#*=}"
            ;;
        --restore)
            RESTORE=true
            ;;
        --help|-h)
            echo "Usage: ./inject_drift.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --scenario=security-group   Inject unauthorized open port 8080 into security group (Default)"
            echo "  --scenario=tags             Modify tags on VPC out-of-band"
            echo "  --scenario=all              Inject both firewall and tag drift"
            echo "  --restore                   Manually revoke injected drift out-of-band"
            echo "  --help, -h                  Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./inject_drift.sh --help for usage."
            exit 1
            ;;
    esac
done

# Select IaC engine
IAC_BIN=""
if command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
elif command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
else
    echo -e "${CLR_RED}Error: Neither 'terraform' nor 'tofu' found in PATH.${CLR_RESET}"
    exit 1
fi

# Fetch resource IDs from Terraform state
if [[ ! -d "${TERRAFORM_DIR}/.terraform" ]] && [[ ! -f "${TERRAFORM_DIR}/terraform.tfstate" ]]; then
    echo -e "${CLR_RED}Error: Terraform state not found. Please apply infrastructure first.${CLR_RESET}"
    exit 1
fi

cd "$TERRAFORM_DIR"
SG_ID=$($IAC_BIN output -raw security_group_id 2>/dev/null || echo "")
VPC_ID=$($IAC_BIN output -raw vpc_id 2>/dev/null || echo "")
BUCKET_ID=$($IAC_BIN output -raw s3_bucket_id 2>/dev/null || echo "")
cd "$SCRIPT_DIR"

if [[ -z "$SG_ID" || -z "$VPC_ID" ]]; then
    echo -e "${CLR_RED}Error: Failed to read resource outputs from Terraform state.${CLR_RESET}"
    exit 1
fi

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ Terraform Out-of-Band Cloud Drift Injector"
echo "======================================================================"
echo -e "${CLR_RESET}"

if [[ "$RESTORE" == true ]]; then
    echo -e "${CLR_YELLOW}▶ Restoring / revoking out-of-band changes...${CLR_RESET}"
    # Revoke port 8080
    $AWS_CLI ec2 revoke-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 8080 \
        --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Revoked rogue port 8080 ingress rule on ${SG_ID}."

    # Restore VPC tags
    $AWS_CLI ec2 create-tags \
        --resources "$VPC_ID" \
        --tags Key=Compliance,Value=Strict >/dev/null 2>&1 || true
    $AWS_CLI ec2 delete-tags \
        --resources "$VPC_ID" \
        --tags Key=RogueAdmin Key=Tampered >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Restored original tags on VPC ${VPC_ID}."
    exit 0
fi

# Inject drift based on scenario
case "$SCENARIO" in
    security-group)
        echo -e "${CLR_YELLOW}▶ Injecting Security Group Ingress Drift (Port 8080/tcp open to 0.0.0.0/0)...${CLR_RESET}"
        $AWS_CLI ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 8080 \
            --cidr 0.0.0.0/0 >/dev/null
        echo -e "  [${CLR_RED}DRIFT INJECTED${CLR_RESET}] Unauthorized ingress rule added to SG: ${CLR_BOLD}${SG_ID}${CLR_RESET}"
        echo -e "  Rule: TCP port 8080 from 0.0.0.0/0 (Not tracked in Terraform code!)"
        ;;

    tags)
        echo -e "${CLR_YELLOW}▶ Injecting Tag Modification Drift on VPC (${VPC_ID})...${CLR_RESET}"
        $AWS_CLI ec2 create-tags \
            --resources "$VPC_ID" \
            --tags Key=Compliance,Value=NON_COMPLIANT_BYPASS Key=RogueAdmin,Value=unauthorized_user >/dev/null
        echo -e "  [${CLR_RED}DRIFT INJECTED${CLR_RESET}] Tags altered out-of-band on VPC: ${CLR_BOLD}${VPC_ID}${CLR_RESET}"
        echo -e "  Tags modified: Compliance=NON_COMPLIANT_BYPASS, RogueAdmin=unauthorized_user"
        ;;

    all)
        echo -e "${CLR_YELLOW}▶ Injecting Multiple Drift Scenarios (Security Group + Tags)...${CLR_RESET}"
        $AWS_CLI ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 8080 \
            --cidr 0.0.0.0/0 >/dev/null
        $AWS_CLI ec2 create-tags \
            --resources "$VPC_ID" \
            --tags Key=Compliance,Value=NON_COMPLIANT_BYPASS Key=RogueAdmin,Value=unauthorized_user >/dev/null
        echo -e "  [${CLR_RED}DRIFT INJECTED${CLR_RESET}] Multiple out-of-band modifications applied successfully."
        ;;

    *)
        echo -e "${CLR_RED}Error: Unknown scenario '${SCENARIO}'.${CLR_RESET}"
        echo "Valid scenarios: security-group, tags, all"
        exit 1
        ;;
esac

echo -e "\n${CLR_YELLOW}💡 Hint: Run './drift_detector.sh' now to detect and analyze this drift!${CLR_RESET}\n"
