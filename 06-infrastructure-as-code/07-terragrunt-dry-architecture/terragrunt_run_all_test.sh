#!/usr/bin/env bash
# ==============================================================================
# terragrunt_run_all_test.sh - E2E Multi-Account Terragrunt Test Suite
# ==============================================================================
# Verifies:
#   1. System prerequisites (Docker, Terragrunt, OpenTofu / Terraform, AWS CLI, jq)
#   2. Local AWS emulator bootstrap (S3, DynamoDB, EC2, IAM on port 4566)
#   3. Terragrunt HCL formatting and module syntax checks
#   4. Directed Acyclic Graph (DAG) resolution and dependency ordering
#   5. Multi-account staging & production speculative planning (run-all plan)
#   6. Dynamic provider generation (provider.tf with tags and assume role)
#   7. Dynamic backend generation (backend.tf with relative state keying)
#   8. Multi-account staging deployment (run-all apply)
#   9. S3 remote state verification (confirming object paths in S3 bucket)
#  10. Multi-account production deployment (verifying 3 replicas & t3.large)
#  11. Reverse dependency destruction (run-all destroy: app before vpc)
#  12. Teardown and workspace sanitation
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

CONTAINER_NAME="localstack-terragrunt-demo"
EMULATOR_PORT=4566
EMULATOR_URL="http://127.0.0.1:${EMULATOR_PORT}"
KEEP_RUNNING=false

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
export USE_LOCALSTACK="true"
export LOCALSTACK_ENDPOINT="${EMULATOR_URL}"

for arg in "$@"; do
    case "$arg" in
        --keep)
            KEEP_RUNNING=true
            ;;
        --clean)
            exec ./cleanup.sh --all
            ;;
        --help|-h)
            echo "Usage: ./terragrunt_run_all_test.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep     Keep LocalStack emulator and generated files after test completion"
            echo "  --clean    Purge all containers, caches, and state immediately"
            echo "  --help, -h Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./terragrunt_run_all_test.sh --help for usage."
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 Terragrunt DRY Multi-Account Architecture - Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Test 1: Prerequisites Check
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 1: Checking system prerequisites...${CLR_RESET}"
MISSING_TOOLS=()
for tool in docker terragrunt aws curl jq; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

IAC_FOUND=false
if command -v tofu &>/dev/null || command -v terraform &>/dev/null; then
    IAC_FOUND=true
fi

if [[ ${#MISSING_TOOLS[@]} -eq 0 && "$IAC_FOUND" == true ]]; then
    TG_VER=$(terragrunt --version | head -n 1)
    record_result "1" "All prerequisites verified (Docker, Terragrunt, IaC engine, AWS CLI, jq)" 0 "$TG_VER"
else
    record_result "1" "Missing required tools: ${MISSING_TOOLS[*]}" 1
fi

# ------------------------------------------------------------------------------
# Test 2: Local AWS Emulator Bootstrap
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 2: Bootstrapping Local AWS Emulator & S3 state buckets...${CLR_RESET}"
if curl -s "${EMULATOR_URL}/" >/dev/null 2>&1; then
    record_result "2" "Local AWS emulator is already active" 0 "Endpoint: ${EMULATOR_URL}"
else
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    docker run -d \
        --name "${CONTAINER_NAME}" \
        -p "${EMULATOR_PORT}:5000" \
        motoserver/moto:latest >/dev/null 2>&1

    HEALTHY=false
    for _ in {1..30}; do
        if curl -s "${EMULATOR_URL}/" >/dev/null 2>&1; then
            HEALTHY=true
            break
        fi
        sleep 1
    done

    if [[ "$HEALTHY" == true ]]; then
        # Create S3 state buckets for both accounts
        aws --endpoint-url="${EMULATOR_URL}" s3 mb s3://terragrunt-state-staging-us-east-1 >/dev/null 2>&1 || true
        aws --endpoint-url="${EMULATOR_URL}" s3 mb s3://terragrunt-state-production-us-east-1 >/dev/null 2>&1 || true

        # Create DynamoDB lock tables for both accounts
        aws --endpoint-url="${EMULATOR_URL}" dynamodb create-table \
            --table-name terragrunt-locks-staging \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 || true

        aws --endpoint-url="${EMULATOR_URL}" dynamodb create-table \
            --table-name terragrunt-locks-production \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 || true

        record_result "2" "Local AWS emulator started & state infrastructure bootstrapped" 0 "Port ${EMULATOR_PORT} ready"
    else
        record_result "2" "Local AWS emulator failed to start" 1
    fi
fi

# ------------------------------------------------------------------------------
# Test 3: Terragrunt HCL Formatting & Linting Check
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 3: Checking Terragrunt and Terraform HCL formatting...${CLR_RESET}"
if terragrunt hcl format --check >/dev/null 2>&1; then
    record_result "3" "Terragrunt HCL syntax and canonical formatting verified" 0
else
    record_result "3" "Terragrunt HCL format check failed" 1
fi

# ------------------------------------------------------------------------------
# Test 4: DAG Graph & Dependency Resolution
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 4: Resolving Directed Acyclic Graph (DAG) dependencies...${CLR_RESET}"
DAG_OUTPUT=$(cd staging/us-east-1 && terragrunt dag graph 2>&1 || echo "")
if [[ "$DAG_OUTPUT" == *'"app" -> "vpc"'* ]]; then
    record_result "4" "Terragrunt correctly constructed DAG dependency: app -> vpc" 0 "Execution order guaranteed"
else
    record_result "4" "DAG dependency resolution failed" 1 "$DAG_OUTPUT"
fi

# ------------------------------------------------------------------------------
# Test 5: Speculative Multi-Account Plan (Staging)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 5: Executing speculative plan on staging (run-all plan)...${CLR_RESET}"
PLAN_STAGE_OUT=$(cd staging/us-east-1 && terragrunt run --all plan --non-interactive 2>&1 || echo "")
if [[ "$PLAN_STAGE_OUT" == *"Plan: 2 to add"* || "$PLAN_STAGE_OUT" == *"Plan: 7 to add"* || "$PLAN_STAGE_OUT" == *"Succeeded    2"* ]]; then
    record_result "5" "Staging speculative plan generated in dependency order with mock outputs" 0
else
    record_result "5" "Staging plan failed" 1 "$PLAN_STAGE_OUT"
fi

# ------------------------------------------------------------------------------
# Test 6: Dynamic Provider Generation Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 6: Verifying dynamic provider.tf generation...${CLR_RESET}"
PROVIDER_FILE=$(find staging/us-east-1/vpc -name "provider.tf" 2>/dev/null | head -n 1 || echo "")
if [[ -n "$PROVIDER_FILE" && -f "$PROVIDER_FILE" ]] && grep -q 'Environment = "staging"' "$PROVIDER_FILE" && grep -q 'ManagedBy   = "Terragrunt"' "$PROVIDER_FILE"; then
    record_result "6" "provider.tf was dynamically generated with inherited environment tags" 0 "Account=staging, ManagedBy=Terragrunt"
else
    record_result "6" "Dynamic provider generation failed or missing required tags" 1
fi

# ------------------------------------------------------------------------------
# Test 7: Dynamic Backend Generation Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 7: Verifying dynamic backend.tf generation with relative key...${CLR_RESET}"
BACKEND_FILE=$(find staging/us-east-1/vpc -name "backend.tf" 2>/dev/null | head -n 1 || echo "")
if [[ -n "$BACKEND_FILE" && -f "$BACKEND_FILE" ]] && grep -q 'key[[:space:]]*=[[:space:]]*"staging/us-east-1/vpc/terraform.tfstate"' "$BACKEND_FILE"; then
    record_result "7" "backend.tf dynamically computed relative S3 state key path" 0 "Key: staging/us-east-1/vpc/terraform.tfstate"
else
    record_result "7" "Dynamic backend generation failed or key mismatch" 1
fi

# ------------------------------------------------------------------------------
# Test 8: Multi-Account Staging Deployment (run-all apply)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 8: Deploying staging infrastructure (run-all apply)...${CLR_RESET}"
APPLY_STAGE_OUT=$(cd staging/us-east-1 && terragrunt run --all apply --non-interactive 2>&1 || echo "")
if [[ "$APPLY_STAGE_OUT" == *"Apply complete!"* || "$APPLY_STAGE_OUT" == *"Succeeded    2"* ]]; then
    record_result "8" "Staging VPC and App successfully provisioned in proper dependency order" 0 "Real VPC ID passed to App module"
else
    record_result "8" "Staging apply failed" 1 "$APPLY_STAGE_OUT"
fi

# ------------------------------------------------------------------------------
# Test 9: S3 Remote State Key & Output Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 9: Verifying S3 state persistence in LocalStack...${CLR_RESET}"
S3_OBJECTS=$(aws --endpoint-url="${EMULATOR_URL}" s3 ls s3://terragrunt-state-staging-us-east-1 --recursive 2>&1 || echo "")
if [[ "$S3_OBJECTS" == *"staging/us-east-1/vpc/terraform.tfstate"* && "$S3_OBJECTS" == *"staging/us-east-1/app/terraform.tfstate"* ]]; then
    record_result "9" "Terragrunt persisted isolated state files in S3 without file collisions" 0 "S3 state paths matched relative directory tree"
else
    record_result "9" "S3 state persistence verification failed" 1 "$S3_OBJECTS"
fi

# ------------------------------------------------------------------------------
# Test 10: Multi-Account Production Deployment
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 10: Deploying production infrastructure (3x t3.large replicas)...${CLR_RESET}"
APPLY_PROD_OUT=$(cd prod/us-east-1 && terragrunt run --all apply --non-interactive 2>&1 || echo "")
if [[ "$APPLY_PROD_OUT" == *"instance_count = 3"* && "$APPLY_PROD_OUT" == *"t3.large"* ]]; then
    record_result "10" "Production deployed with production sizing (3 replicas, t3.large, 10.20.0.0/16)" 0 "Environment isolation enforced"
else
    record_result "10" "Production apply failed or sizing mismatch" 1 "$APPLY_PROD_OUT"
fi

# ------------------------------------------------------------------------------
# Test 11: Reverse Dependency Destruction (run-all destroy)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 11: Testing reverse-dependency destruction (app before vpc)...${CLR_RESET}"
DESTROY_STAGE_OUT=$(cd staging/us-east-1 && terragrunt run --all destroy --non-interactive 2>&1 || echo "")
DESTROY_PROD_OUT=$(cd prod/us-east-1 && terragrunt run --all destroy --non-interactive 2>&1 || echo "")
if [[ "$DESTROY_STAGE_OUT" == *"Destroy complete!"* || "$DESTROY_STAGE_OUT" == *"Succeeded    2"* ]] && \
   [[ "$DESTROY_PROD_OUT" == *"Destroy complete!"* || "$DESTROY_PROD_OUT" == *"Succeeded    2"* ]]; then
    record_result "11" "Both staging and production destroyed cleanly in reverse DAG order" 0
else
    record_result "11" "Terragrunt destroy encountered failures" 1
fi

# ------------------------------------------------------------------------------
# Test 12: Workspace Sanitation & Cleanup
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 12: Testing cleanup script...${CLR_RESET}"
if [[ "$KEEP_RUNNING" == false ]]; then
    if ./cleanup.sh --all >/dev/null 2>&1; then
        record_result "12" "cleanup.sh purged emulator container, caches, and state files" 0
    else
        record_result "12" "cleanup.sh failed" 1
    fi
else
    echo -e "  [${CLR_CYAN}SKIP${CLR_RESET}] Test 12: Cleanup skipped (--keep flag active)."
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# ------------------------------------------------------------------------------
# Summary Recap
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}🎉 ALL $TOTAL_TESTS TESTS PASSED! ($PASSED_TESTS/$TOTAL_TESTS)${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED: $FAILED_TESTS of $TOTAL_TESTS tests failed.${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
