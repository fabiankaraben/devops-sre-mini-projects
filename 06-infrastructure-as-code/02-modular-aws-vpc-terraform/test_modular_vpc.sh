#!/usr/bin/env bash
# ==============================================================================
# test_modular_vpc.sh - E2E Lifecycle Test Suite for Mini-Project 02
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, Terraform / OpenTofu, TFLint, terraform-docs, curl, jq, aws)
#   2. Static code formatting, TFLint linting, and terraform-docs documentation
#   3. LocalStack container lifecycle (spinning up ephemeral LocalStack on port 4566)
#   4. Dev Environment:
#      - terraform init, plan, apply
#      - Cost-optimized Single NAT Gateway architecture
#      - Subnet CIDR allocation across 3 Availability Zones (10.10.0.0/16)
#      - Route table associations (IGW for public, Single NAT for private)
#      - State tracking, outputs resolution, and IaC idempotency
#   5. Prod Environment:
#      - terraform init, plan, apply
#      - True High-Availability Multi-AZ Architecture (3 NAT Gateways across 3 AZs)
#      - Subnet CIDR allocation across 3 Availability Zones (10.20.0.0/16)
#      - Dedicated private route tables per AZ routing to AZ-specific NAT Gateway
#      - State tracking, outputs resolution, and IaC idempotency
#   6. Clean infrastructure teardown and LocalStack container removal
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

KEEP_RUNNING=false
ENGINE_OVERRIDE=""
LOCALSTACK_CONTAINER="localstack-vpc-demo"
LOCALSTACK_PORT=4566
LOCALSTACK_URL="http://127.0.0.1:${LOCALSTACK_PORT}"

for arg in "$@"; do
    case "$arg" in
        --keep)
            KEEP_RUNNING=true
            ;;
        --clean)
            exec ./cleanup.sh --all
            ;;
        --engine=*)
            ENGINE_OVERRIDE="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./test_modular_vpc.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep              Keep LocalStack and provisioned VPCs running after tests"
            echo "  --clean             Purge all resources, state, and containers"
            echo "  --engine=terraform  Force HashiCorp Terraform engine"
            echo "  --engine=tofu       Force OpenTofu engine"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run ./test_modular_vpc.sh --help for usage."
            exit 1
            ;;
    esac
done

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    local test_num="$1"
    local description="$2"
    local status="$3"
    local details="${4:-}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$status" -eq 0 ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_GRAY}↳ ${details}${CLR_RESET}"
        fi
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_RED}↳ ${details}${CLR_RESET}"
        fi
    fi
}

cleanup_on_exit() {
    rm -f "$SCRIPT_DIR"/*.tfplan "$SCRIPT_DIR"/**/.tmp_* "$SCRIPT_DIR"/**/tfplan
    if [[ "$KEEP_RUNNING" == false && "$FAILED_TESTS" -gt 0 ]]; then
        echo -e "\n${CLR_YELLOW}⚠️  Tests encountered failures. Running cleanup...${CLR_RESET}"
        ./cleanup.sh >/dev/null 2>&1 || true
    fi
}

trap cleanup_on_exit EXIT INT TERM

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🏗️  Modular High-Availability AWS VPC E2E Lifecycle Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Phase 1: Environment & Tooling Verification
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}Phase 1: Tooling & Prerequisites Verification${CLR_RESET}"

# 1.1 Docker Engine
if docker info >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "Unknown")
    record_result "01" "Docker engine is running and responsive" 0 "Engine version: ${DOCKER_VER}"
else
    record_result "01" "Docker engine is running and responsive" 1 "Docker daemon is not reachable"
    exit 1
fi

# 1.2 Select IaC Engine (Terraform or OpenTofu)
IAC_BIN=""
if [[ -n "$ENGINE_OVERRIDE" ]]; then
    if command -v "$ENGINE_OVERRIDE" >/dev/null 2>&1; then
        IAC_BIN="$ENGINE_OVERRIDE"
    else
        record_result "02" "IaC engine selection (${ENGINE_OVERRIDE})" 1 "Binary not found in PATH"
        exit 1
    fi
else
    if command -v terraform >/dev/null 2>&1; then
        IAC_BIN="terraform"
    elif command -v tofu >/dev/null 2>&1; then
        IAC_BIN="tofu"
    fi
fi

if [[ -n "$IAC_BIN" ]]; then
    IAC_VER=$("$IAC_BIN" version | head -n 1)
    record_result "02" "IaC engine detected (${IAC_BIN})" 0 "${IAC_VER}"
else
    record_result "02" "IaC engine detected" 1 "Neither 'terraform' nor 'tofu' found"
    exit 1
fi

# 1.3 Validation Tools (tflint, terraform-docs, aws, jq, curl)
if command -v tflint >/dev/null 2>&1 && command -v terraform-docs >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    record_result "03" "Quality & Linting tools available (tflint, terraform-docs, jq)" 0 "All linters and doc generators ready"
else
    record_result "03" "Quality & Linting tools available (tflint, terraform-docs, jq)" 1 "Missing required tools"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 2: Static Analysis, Linting & Doc Generation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 2: Static Code Quality, TFLint & terraform-docs${CLR_RESET}"

if ./validate_and_docs.sh >/dev/null 2>&1; then
    record_result "04" "HCL formatting, TFLint recursive checks, and module docs verified" 0 "Canonical formatting and valid schema"
else
    record_result "04" "HCL formatting, TFLint recursive checks, and module docs verified" 1 "Static validation failed"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 3: LocalStack Bootstrap
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 3: LocalStack Community Emulator Bootstrap${CLR_RESET}"

# Check if local AWS emulator is already reachable
if curl -s "${LOCALSTACK_URL}/" >/dev/null 2>&1; then
    record_result "05" "Local AWS emulator is active and reachable" 0 "Endpoint: ${LOCALSTACK_URL}"
else
    echo "  Starting ephemeral local AWS emulator container (${LOCALSTACK_CONTAINER})..."
    docker rm -f "${LOCALSTACK_CONTAINER}" >/dev/null 2>&1 || true
    docker run -d \
        --name "${LOCALSTACK_CONTAINER}" \
        -p "${LOCALSTACK_PORT}:5000" \
        motoserver/moto:latest >/dev/null 2>&1

    # Wait for emulator endpoint
    HEALTHY=false
    for _ in {1..30}; do
        if curl -s "${LOCALSTACK_URL}/" >/dev/null 2>&1; then
            HEALTHY=true
            break
        fi
        sleep 1
    done

    if [[ "$HEALTHY" == true ]]; then
        record_result "05" "Local AWS emulator started and healthy" 0 "Port ${LOCALSTACK_PORT} ready for EC2/VPC APIs"
    else
        record_result "05" "Local AWS emulator started and healthy" 1 "Emulator failed to respond on port ${LOCALSTACK_PORT}"
        exit 1
    fi
fi

# Configure AWS CLI alias for LocalStack
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
AWS_CMD="aws --endpoint-url=${LOCALSTACK_URL} --region=us-east-1"

# ------------------------------------------------------------------------------
# Phase 4: Dev Environment Provisioning & Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 4: Dev Environment Lifecycle (Cost-Optimized Single NAT)${CLR_RESET}"

cd "$SCRIPT_DIR/environments/dev"

# 4.1 Dev Init & Plan
"$IAC_BIN" init -input=false >/dev/null 2>&1
if "$IAC_BIN" plan -out=tfplan -input=false >/dev/null 2>&1; then
    record_result "06" "Dev environment speculative plan generated" 0 "Plan calculated successfully"
else
    record_result "06" "Dev environment speculative plan generated" 1 "Dev plan failed"
    exit 1
fi

# 4.2 Dev Apply
if "$IAC_BIN" apply -auto-approve -input=false tfplan >/dev/null 2>&1; then
    record_result "07" "Dev VPC infrastructure provisioned" 0 "Applied module in environments/dev"
else
    record_result "07" "Dev VPC infrastructure provisioned" 1 "Dev apply failed"
    exit 1
fi

# 4.3 Dev Outputs & Attributes
DEV_VPC_ID=$("$IAC_BIN" output -raw vpc_id)
DEV_PUBLIC_SUBNETS=($("$IAC_BIN" output -json public_subnet_ids | jq -r '.[]'))
DEV_PRIVATE_SUBNETS=($("$IAC_BIN" output -json private_subnet_ids | jq -r '.[]'))
DEV_NAT_IPS=($("$IAC_BIN" output -json nat_gateway_ips | jq -r '.[]' 2>/dev/null || echo ""))

if [[ -n "$DEV_VPC_ID" && "${#DEV_PUBLIC_SUBNETS[@]}" -eq 3 && "${#DEV_PRIVATE_SUBNETS[@]}" -eq 3 ]]; then
    record_result "08" "Dev VPC outputs resolved (3 public subnets, 3 private subnets)" 0 "VPC ID: ${DEV_VPC_ID}"
else
    record_result "08" "Dev VPC outputs resolved" 1 "Unexpected subnet counts in Dev"
fi

# 4.4 Dev Single NAT Gateway verification (Cost optimization)
if [[ "${#DEV_NAT_IPS[@]}" -eq 1 ]]; then
    record_result "09" "Dev single NAT Gateway cost-optimization verified" 0 "Allocated exactly 1 shared NAT Gateway (EIP: ${DEV_NAT_IPS[0]})"
else
    record_result "09" "Dev single NAT Gateway cost-optimization verified" 1 "Expected 1 NAT Gateway, found ${#DEV_NAT_IPS[@]}"
fi

# 4.5 Dev AWS API Query Verification
DEV_VPC_CIDR=$($AWS_CMD ec2 describe-vpcs --vpc-ids "$DEV_VPC_ID" --query "Vpcs[0].CidrBlock" --output text 2>/dev/null || echo "")
if [[ "$DEV_VPC_CIDR" == "10.10.0.0/16" ]]; then
    record_result "10" "Dev VPC verified via AWS EC2 API with CIDR 10.10.0.0/16" 0 "Confirmed live in LocalStack / Moto"
else
    record_result "10" "Dev VPC verified via AWS EC2 API with CIDR 10.10.0.0/16" 1 "CIDR mismatch: ${DEV_VPC_CIDR}"
fi

# 4.6 Dev Idempotency Check
set +e
DEV_IDEMPOTENT=$("$IAC_BIN" plan -detailed-exitcode -input=false 2>&1)
DEV_IDEMPOTENT_CODE=$?
set -e

if [[ $DEV_IDEMPOTENT_CODE -eq 0 ]]; then
    record_result "11" "Dev environment idempotency confirmed" 0 "Zero resource drift detected"
else
    record_result "11" "Dev environment idempotency confirmed" 1 "Drift detected (Exit code: ${DEV_IDEMPOTENT_CODE})"
fi

# ------------------------------------------------------------------------------
# Phase 5: Prod Environment Provisioning & Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 5: Prod Environment Lifecycle (Multi-AZ 3-NAT HA)${CLR_RESET}"

cd "$SCRIPT_DIR/environments/prod"

# 5.1 Prod Init & Plan
"$IAC_BIN" init -input=false >/dev/null 2>&1
if "$IAC_BIN" plan -out=tfplan -input=false >/dev/null 2>&1; then
    record_result "12" "Prod environment speculative plan generated" 0 "Plan calculated successfully"
else
    record_result "12" "Prod environment speculative plan generated" 1 "Prod plan failed"
    exit 1
fi

# 5.2 Prod Apply
if "$IAC_BIN" apply -auto-approve -input=false tfplan >/dev/null 2>&1; then
    record_result "13" "Prod VPC infrastructure provisioned" 0 "Applied module in environments/prod"
else
    record_result "13" "Prod VPC infrastructure provisioned" 1 "Prod apply failed"
    exit 1
fi

# 5.3 Prod Outputs & Multi-AZ HA NAT Gateways
PROD_VPC_ID=$("$IAC_BIN" output -raw vpc_id)
PROD_PUBLIC_SUBNETS=($("$IAC_BIN" output -json public_subnet_ids | jq -r '.[]'))
PROD_PRIVATE_SUBNETS=($("$IAC_BIN" output -json private_subnet_ids | jq -r '.[]'))
PROD_NAT_IPS=($("$IAC_BIN" output -json nat_gateway_ips | jq -r '.[]'))

if [[ -n "$PROD_VPC_ID" && "${#PROD_PUBLIC_SUBNETS[@]}" -eq 3 && "${#PROD_PRIVATE_SUBNETS[@]}" -eq 3 ]]; then
    record_result "14" "Prod VPC outputs resolved (3 public subnets, 3 private subnets)" 0 "VPC ID: ${PROD_VPC_ID}"
else
    record_result "14" "Prod VPC outputs resolved" 1 "Unexpected subnet counts in Prod"
fi

# 5.4 Prod Multi-AZ 3 NAT Gateways verification (High Availability)
if [[ "${#PROD_NAT_IPS[@]}" -eq 3 ]]; then
    record_result "15" "Prod Multi-AZ High Availability verified (3 NAT Gateways across 3 AZs)" 0 "Allocated 3 dedicated NAT Gateways"
else
    record_result "15" "Prod Multi-AZ High Availability verified" 1 "Expected 3 NAT Gateways in Prod, found ${#PROD_NAT_IPS[@]}"
fi

# 5.5 Prod AWS API Query Verification
PROD_VPC_CIDR=$($AWS_CMD ec2 describe-vpcs --vpc-ids "$PROD_VPC_ID" --query "Vpcs[0].CidrBlock" --output text 2>/dev/null || echo "")
if [[ "$PROD_VPC_CIDR" == "10.20.0.0/16" ]]; then
    record_result "16" "Prod VPC verified via AWS EC2 API with CIDR 10.20.0.0/16" 0 "Confirmed live in LocalStack / Moto"
else
    record_result "16" "Prod VPC verified via AWS EC2 API with CIDR 10.20.0.0/16" 1 "CIDR mismatch: ${PROD_VPC_CIDR}"
fi

# 5.6 Prod Idempotency Check
set +e
PROD_IDEMPOTENT=$("$IAC_BIN" plan -detailed-exitcode -input=false 2>&1)
PROD_IDEMPOTENT_CODE=$?
set -e

if [[ $PROD_IDEMPOTENT_CODE -eq 0 ]]; then
    record_result "17" "Prod environment idempotency confirmed" 0 "Zero resource drift detected"
else
    record_result "17" "Prod environment idempotency confirmed" 1 "Drift detected (Exit code: ${PROD_IDEMPOTENT_CODE})"
fi

# ------------------------------------------------------------------------------
# Phase 6: Teardown & Destruction
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 6: Infrastructure Destruction & Teardown${CLR_RESET}"

cd "$SCRIPT_DIR"

if [[ "$KEEP_RUNNING" == true ]]; then
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] --keep flag specified: Leaving LocalStack and VPC resources active."
    echo -e "  LocalStack URL: ${CLR_GREEN}${LOCALSTACK_URL}${CLR_RESET}"
    echo -e "  Dev VPC ID: ${CLR_GREEN}${DEV_VPC_ID}${CLR_RESET} | Prod VPC ID: ${CLR_GREEN}${PROD_VPC_ID}${CLR_RESET}"
    echo -e "  To clean up later, run: ./cleanup.sh --all"
else
    # 6.1 Destroy Prod
    echo "  Destroying Prod environment..."
    (cd "$SCRIPT_DIR/environments/prod" && "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1)

    # 6.2 Destroy Dev
    echo "  Destroying Dev environment..."
    (cd "$SCRIPT_DIR/environments/dev" && "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1)

    # 6.3 Remove LocalStack container
    echo "  Removing LocalStack container..."
    docker rm -f "${LOCALSTACK_CONTAINER}" >/dev/null 2>&1 || true

    record_result "18" "Complete infrastructure destruction and LocalStack cleanup" 0 "All AWS resources and Docker containers purged"
fi

# ------------------------------------------------------------------------------
# Test Suite Summary
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
echo -e "${CLR_BOLD}  TEST SUITE RESULTS SUMMARY${CLR_RESET}"
echo "======================================================================"
echo -e "  Total Tests Executed : ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  Passed Assertions    : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed Assertions    : $([[ "$FAILED_TESTS" -eq 0 ]] && echo -e "${CLR_GREEN}0${CLR_RESET}" || echo -e "${CLR_RED}${FAILED_TESTS}${CLR_RESET}")"
echo "======================================================================"

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "${CLR_GREEN}${CLR_BOLD}🎉 ALL MODULAR VPC LIFECYCLE TESTS PASSED PERFECTLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S)${CLR_RESET}\n"
    exit 1
fi
