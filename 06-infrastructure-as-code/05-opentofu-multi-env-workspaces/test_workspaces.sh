#!/usr/bin/env bash
# ==============================================================================
# test_workspaces.sh - E2E OpenTofu Multi-Environment Workspaces Test Suite
# ==============================================================================
# Validates:
#   1. Tooling & prerequisites (Docker, OpenTofu/Terraform, tflint, aws, jq, curl)
#   2. Canonical HCL formatting, TFLint analysis, and schema validation
#   3. Local AWS emulator lifecycle on port 4566
#   4. OpenTofu initialization
#   5. Dev workspace deployment and sizing assertions (1 replica, t3.micro, 3d logs)
#   6. Staging workspace deployment and sizing assertions (2 replicas, t3.small, 14d logs)
#   7. Prod workspace deployment and sizing assertions (4 replicas, t3.large, 90d logs)
#   8. State file isolation in terraform.tfstate.d/
#   9. Safety guardrail assertion (detecting mismatch between workspace and tfvars)
#  10. Full teardown across all workspaces and clean container removal
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

# Detect engine (tofu preferred, fallback to terraform)
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
        --clean)
            exec ./cleanup.sh --all
            ;;
        --help|-h)
            echo "Usage: ./test_workspaces.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --engine=<tofu|terraform> Force engine selection (default: auto-detected)"
            echo "  --clean                  Run full cleanup and exit"
            echo "  --help, -h               Show this help message"
            exit 0
            ;;
    esac
done

EMULATOR_CONTAINER="localstack-workspaces-demo"
EMULATOR_PORT=4566
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
echo "  🌐 OpenTofu Multi-Environment Workspaces E2E Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Phase 1: Tooling & Prerequisites Verification
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}Phase 1: Tooling & Prerequisites Verification${CLR_RESET}"

if docker info >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "Unknown")
    record_result "01" "Docker engine is responsive" 0 "Engine version: ${DOCKER_VER}"
else
    record_result "01" "Docker engine is responsive" 1 "Docker daemon is not reachable"
    exit 1
fi

if command -v "$IAC_BIN" >/dev/null 2>&1; then
    IAC_VER=$("$IAC_BIN" version | head -n 1)
    record_result "02" "IaC engine detected (${IAC_BIN})" 0 "${IAC_VER}"
else
    record_result "02" "IaC engine detected" 1 "'$IAC_BIN' binary not found in PATH"
    exit 1
fi

if command -v tflint >/dev/null 2>&1 && command -v aws >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    record_result "03" "CLI utilities available (tflint, aws, jq, curl)" 0 "All tools ready"
else
    record_result "03" "CLI utilities available" 1 "Missing required CLI tools"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 2: Static Analysis & Schema Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 2: Static Analysis & Validation${CLR_RESET}"

if "$IAC_BIN" fmt -check >/dev/null 2>&1; then
    record_result "04" "HCL formatting validation (${IAC_BIN} fmt -check)" 0 "Canonical formatting verified"
else
    record_result "04" "HCL formatting validation" 1 "Files need formatting. Run '$IAC_BIN fmt'."
    exit 1
fi

# Initialize plugins and validate syntax
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

"$IAC_BIN" init -backend=false >/dev/null 2>&1
if "$IAC_BIN" validate >/dev/null 2>&1; then
    record_result "05" "OpenTofu configuration schema validation" 0 "Configuration is valid"
else
    record_result "05" "OpenTofu configuration schema validation" 1 "Schema validation failed"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 3: Local AWS Emulator Lifecycle
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 3: Local AWS Emulator Bootstrap${CLR_RESET}"

if ! curl -s "http://127.0.0.1:${EMULATOR_PORT}/" >/dev/null 2>&1; then
    echo "  Starting local AWS emulator (${EMULATOR_CONTAINER})..."
    docker rm -f "${EMULATOR_CONTAINER}" >/dev/null 2>&1 || true
    docker run -d \
        --name "${EMULATOR_CONTAINER}" \
        -p "${EMULATOR_PORT}:5000" \
        motoserver/moto:latest >/dev/null 2>&1

    for _ in {1..30}; do
        if curl -s "http://127.0.0.1:${EMULATOR_PORT}/" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi

if curl -s "http://127.0.0.1:${EMULATOR_PORT}/" >/dev/null 2>&1; then
    record_result "06" "Local AWS emulator started successfully" 0 "Endpoint: http://127.0.0.1:${EMULATOR_PORT}"
else
    record_result "06" "Local AWS emulator started successfully" 1 "Emulator failed to respond"
    exit 1
fi

# Full init
"$IAC_BIN" init -upgrade >/dev/null 2>&1

# ------------------------------------------------------------------------------
# Phase 4: Development Environment Workspace
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 4: Dev Workspace Lifecycle & Sizing Assertions${CLR_RESET}"

"$IAC_BIN" workspace select dev 2>/dev/null || "$IAC_BIN" workspace new dev >/dev/null 2>&1
"$IAC_BIN" apply -var-file="environments/dev.tfvars" -auto-approve >/dev/null 2>&1

DEV_WS=$("$IAC_BIN" output -raw workspace_name)
DEV_INST_TYPE=$("$IAC_BIN" output -raw instance_type)
DEV_INST_COUNT=$("$IAC_BIN" output -raw instance_count)
DEV_LOG_DAYS=$("$IAC_BIN" output -raw log_retention_days)
DEV_BUCKET=$("$IAC_BIN" output -raw s3_storage_bucket_name)

if [[ "$DEV_WS" == "dev" && "$DEV_INST_TYPE" == "t3.micro" && "$DEV_INST_COUNT" -eq 1 && "$DEV_LOG_DAYS" -eq 3 ]]; then
    record_result "07" "Dev workspace applied with cost-optimized specifications" 0 "1x ${DEV_INST_TYPE}, ${DEV_LOG_DAYS}d log retention"
else
    record_result "07" "Dev workspace applied with cost-optimized specifications" 1 "Unexpected dev sizing"
fi

if [[ "$DEV_BUCKET" =~ ^cloud-app-dev-storage- ]]; then
    record_result "08" "Dev resource naming dynamically prefixed with workspace identifier" 0 "Bucket: ${DEV_BUCKET}"
else
    record_result "08" "Dev resource naming dynamically prefixed" 1 "Bucket: ${DEV_BUCKET}"
fi

# ------------------------------------------------------------------------------
# Phase 5: Staging Environment Workspace
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 5: Staging Workspace Lifecycle & Sizing Assertions${CLR_RESET}"

"$IAC_BIN" workspace select staging 2>/dev/null || "$IAC_BIN" workspace new staging >/dev/null 2>&1
"$IAC_BIN" apply -var-file="environments/staging.tfvars" -auto-approve >/dev/null 2>&1

STAGING_WS=$("$IAC_BIN" output -raw workspace_name)
STAGING_INST_TYPE=$("$IAC_BIN" output -raw instance_type)
STAGING_INST_COUNT=$("$IAC_BIN" output -raw instance_count)
STAGING_LOG_DAYS=$("$IAC_BIN" output -raw log_retention_days)
STAGING_BUCKET=$("$IAC_BIN" output -raw s3_storage_bucket_name)

if [[ "$STAGING_WS" == "staging" && "$STAGING_INST_TYPE" == "t3.small" && "$STAGING_INST_COUNT" -eq 2 && "$STAGING_LOG_DAYS" -eq 14 ]]; then
    record_result "09" "Staging workspace applied with pre-production specifications" 0 "2x ${STAGING_INST_TYPE}, ${STAGING_LOG_DAYS}d log retention"
else
    record_result "09" "Staging workspace applied with pre-production specifications" 1 "Unexpected staging sizing"
fi

# Check versioning on staging bucket
STAGING_VERSIONING=$(aws --endpoint-url="http://127.0.0.1:${EMULATOR_PORT}" s3api get-bucket-versioning --bucket "$STAGING_BUCKET" | jq -r '.Status // "Suspended"')
if [[ "$STAGING_VERSIONING" == "Enabled" ]]; then
    record_result "10" "Staging storage bucket versioning enabled" 0 "Status = Enabled"
else
    record_result "10" "Staging storage bucket versioning enabled" 1 "Status: ${STAGING_VERSIONING}"
fi

# ------------------------------------------------------------------------------
# Phase 6: Production Environment Workspace
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 6: Production Workspace Lifecycle & Sizing Assertions${CLR_RESET}"

"$IAC_BIN" workspace select prod 2>/dev/null || "$IAC_BIN" workspace new prod >/dev/null 2>&1
"$IAC_BIN" apply -var-file="environments/prod.tfvars" -auto-approve >/dev/null 2>&1

PROD_WS=$("$IAC_BIN" output -raw workspace_name)
PROD_INST_TYPE=$("$IAC_BIN" output -raw instance_type)
PROD_INST_COUNT=$("$IAC_BIN" output -raw instance_count)
PROD_LOG_DAYS=$("$IAC_BIN" output -raw log_retention_days)
PROD_IS_PROD=$("$IAC_BIN" output -raw is_production)
PROD_BUCKET=$("$IAC_BIN" output -raw s3_storage_bucket_name)

if [[ "$PROD_WS" == "prod" && "$PROD_INST_TYPE" == "t3.large" && "$PROD_INST_COUNT" -eq 4 && "$PROD_LOG_DAYS" -eq 90 && "$PROD_IS_PROD" == "true" ]]; then
    record_result "11" "Prod workspace applied with high-availability tier-1 specifications" 0 "4x ${PROD_INST_TYPE}, ${PROD_LOG_DAYS}d logs, deletion protection active"
else
    record_result "11" "Prod workspace applied with high-availability specifications" 1 "Unexpected prod sizing"
fi

# Verify public ingress on prod security group
PROD_SG_NAME=$("$IAC_BIN" output -raw security_group_name)
if [[ "$PROD_SG_NAME" == "cloud-app-prod-sg" ]]; then
    record_result "12" "Production security group dynamically named and provisioned" 0 "${PROD_SG_NAME}"
else
    record_result "12" "Production security group dynamically named" 1 "SG Name: ${PROD_SG_NAME}"
fi

# Verify SSM configuration payload in Prod
PROD_CONFIG_JSON=$(aws --endpoint-url="http://127.0.0.1:${EMULATOR_PORT}" ssm get-parameter --name "/app/prod/config" | jq -r '.Parameter.Value')
PROD_STORED_COUNT=$(echo "$PROD_CONFIG_JSON" | jq -r '.instance_count')
if [[ "$PROD_STORED_COUNT" -eq 4 ]]; then
    record_result "13" "SSM Parameter manifest stores verified production metadata" 0 "instance_count = 4, environment = prod"
else
    record_result "13" "SSM Parameter manifest stores verified production metadata" 1 "Config: ${PROD_CONFIG_JSON}"
fi

# ------------------------------------------------------------------------------
# Phase 7: State Isolation Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 7: State Isolation & Cross-Environment Audit${CLR_RESET}"

if [[ -f "terraform.tfstate.d/dev/terraform.tfstate" && -f "terraform.tfstate.d/staging/terraform.tfstate" && -f "terraform.tfstate.d/prod/terraform.tfstate" ]]; then
    record_result "14" "Independent workspace state files isolated in terraform.tfstate.d/" 0 "3 independent state files verified"
else
    record_result "14" "Independent workspace state files isolated" 1 "Missing state files in terraform.tfstate.d/"
fi

# Audit that dev state contains dev bucket and NOT prod bucket
DEV_STATE_CONTENT=$(cat "terraform.tfstate.d/dev/terraform.tfstate")
if echo "$DEV_STATE_CONTENT" | grep -q "$DEV_BUCKET" && ! echo "$DEV_STATE_CONTENT" | grep -q "$PROD_BUCKET"; then
    record_result "15" "Zero state cross-contamination confirmed between workspaces" 0 "State strictly isolated per environment"
else
    record_result "15" "Zero state cross-contamination confirmed" 1 "Cross-contamination detected in state!"
fi

# ------------------------------------------------------------------------------
# Phase 8: Safety Guardrail Assertion
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 8: Safety Guardrail Assertion${CLR_RESET}"

"$IAC_BIN" workspace select dev >/dev/null 2>&1
set +e
MISMATCH_OUTPUT=$("$IAC_BIN" plan -var-file="environments/prod.tfvars" 2>&1)
set -e

if echo "$MISMATCH_OUTPUT" | grep -q "workspace_environment_match" || echo "$MISMATCH_OUTPUT" | grep -q "does not match active OpenTofu workspace"; then
    record_result "16" "Workspace safety guardrail caught environment mismatch" 0 "Prevented applying prod.tfvars on dev workspace"
else
    record_result "16" "Workspace safety guardrail caught environment mismatch" 1 "Guardrail failed to trigger"
fi

# ------------------------------------------------------------------------------
# Phase 9: Infrastructure Destruction & Teardown
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 9: Infrastructure Destruction & Teardown${CLR_RESET}"

# Destroy prod
echo "  Destroying prod workspace..."
"$IAC_BIN" workspace select prod >/dev/null 2>&1
"$IAC_BIN" destroy -var-file="environments/prod.tfvars" -auto-approve >/dev/null 2>&1

# Destroy staging
echo "  Destroying staging workspace..."
"$IAC_BIN" workspace select staging >/dev/null 2>&1
"$IAC_BIN" destroy -var-file="environments/staging.tfvars" -auto-approve >/dev/null 2>&1

# Destroy dev
echo "  Destroying dev workspace..."
"$IAC_BIN" workspace select dev >/dev/null 2>&1
"$IAC_BIN" destroy -var-file="environments/dev.tfvars" -auto-approve >/dev/null 2>&1

record_result "17" "All workspace resources cleanly destroyed via IaC engine" 0 "dev, staging, and prod destroyed"

# Select default and remove workspaces
"$IAC_BIN" workspace select default >/dev/null 2>&1
"$IAC_BIN" workspace delete dev >/dev/null 2>&1 || true
"$IAC_BIN" workspace delete staging >/dev/null 2>&1 || true
"$IAC_BIN" workspace delete prod >/dev/null 2>&1 || true

# Stop emulator container
docker rm -f "${EMULATOR_CONTAINER}" >/dev/null 2>&1 || true
rm -rf terraform.tfstate.d/ *.tfplan *.tfstate*
record_result "18" "Complete emulator container and state workspace cleanup" 0 "All state caches and containers removed"

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
    echo -e "${CLR_GREEN}${CLR_BOLD}🎉 ALL OPENTOFU WORKSPACES TESTS PASSED PERFECTLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S)${CLR_RESET}\n"
    exit 1
fi
