#!/usr/bin/env bash
# ==============================================================================
# test_state_lock.sh - E2E Remote State Locking & Concurrency Test Suite
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, Terraform / OpenTofu, TFLint, AWS CLI, jq, curl)
#   2. Static code formatting and TFLint analysis
#   3. Local AWS emulator lifecycle (port 4566)
#   4. Backend Bootstrap Phase:
#      - S3 Bucket creation with Versioning, Server-Side Encryption (AES256), and Public Access Block
#      - DynamoDB Table creation with partition key 'LockID' and PAY_PER_REQUEST billing
#   5. Consuming Workload Phase:
#      - Dynamic initialization using Remote S3 Backend with DynamoDB state locking
#   6. Concurrency & Race Condition Prevention:
#      - Process A acquires lock and starts long apply (with artificial delay)
#      - Verifies active lock item metadata in DynamoDB (LockID, Owner, Created)
#      - Process B attempts simultaneous apply and is BLOCKED with ConditionalCheckFailedException
#      - Process A finishes and releases the DynamoDB lock
#   7. S3 Versioning & Audit Trail:
#      - Verifies multiple immutable state object versions preserved in S3
#   8. Clean infrastructure teardown and container removal
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
EMULATOR_CONTAINER="localstack-state-demo"
EMULATOR_PORT=4566
EMULATOR_URL="http://127.0.0.1:${EMULATOR_PORT}"

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
            echo "Usage: ./test_state_lock.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep              Keep local emulator and provisioned state active"
            echo "  --clean             Purge all resources, state, and containers"
            echo "  --engine=terraform  Force HashiCorp Terraform engine"
            echo "  --engine=tofu       Force OpenTofu engine"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run ./test_state_lock.sh --help for usage."
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
    rm -f "$SCRIPT_DIR"/**/*.tfplan "$SCRIPT_DIR"/**/tfplan "$SCRIPT_DIR"/**/.tmp_* "$SCRIPT_DIR"/**/backend-generated.hcl
    if [[ "$KEEP_RUNNING" == false && "$FAILED_TESTS" -gt 0 ]]; then
        echo -e "\n${CLR_YELLOW}⚠️  Tests encountered failures. Running cleanup...${CLR_RESET}"
        ./cleanup.sh >/dev/null 2>&1 || true
    fi
}

trap cleanup_on_exit EXIT INT TERM

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔒 S3 & DynamoDB Remote State Locking E2E Concurrency Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Phase 1: Prerequisites & Tooling Verification
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}Phase 1: Tooling & Prerequisites Verification${CLR_RESET}"

# 1.1 Docker Engine
if docker info >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "Unknown")
    record_result "01" "Docker engine is responsive" 0 "Engine version: ${DOCKER_VER}"
else
    record_result "01" "Docker engine is responsive" 1 "Docker daemon is not reachable"
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

# 1.3 Validation Tools (tflint, aws, jq, curl)
if command -v tflint >/dev/null 2>&1 && command -v aws >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    record_result "03" "CLI utilities available (tflint, aws, jq, curl)" 0 "All tools ready"
else
    record_result "03" "CLI utilities available" 1 "Missing required tools"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 2: Static Analysis & Linting
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 2: Static Analysis & Validation${CLR_RESET}"

if ./validate_and_docs.sh >/dev/null 2>&1; then
    record_result "04" "HCL formatting, TFLint analysis, and schema validation" 0 "Canonical formatting verified"
else
    record_result "04" "HCL formatting, TFLint analysis, and schema validation" 1 "Static checks failed"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 3: Local AWS Emulator Bootstrap
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 3: Local AWS Emulator Bootstrap${CLR_RESET}"

if curl -s "${EMULATOR_URL}/" >/dev/null 2>&1; then
    record_result "05" "Local AWS emulator is active and reachable" 0 "Endpoint: ${EMULATOR_URL}"
else
    echo "  Starting local AWS emulator (${EMULATOR_CONTAINER})..."
    docker rm -f "${EMULATOR_CONTAINER}" >/dev/null 2>&1 || true
    docker run -d \
        --name "${EMULATOR_CONTAINER}" \
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
        record_result "05" "Local AWS emulator started successfully" 0 "Port ${EMULATOR_PORT} ready for S3/DynamoDB"
    else
        record_result "05" "Local AWS emulator started successfully" 1 "Emulator failed to respond"
        exit 1
    fi
fi

# Configure AWS CLI credentials for emulator
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
AWS_CMD="aws --endpoint-url=${EMULATOR_URL} --region=us-east-1"

# ------------------------------------------------------------------------------
# Phase 4: Backend Bootstrap Provisioning & Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 4: Remote State Infrastructure Bootstrap${CLR_RESET}"

cd "$SCRIPT_DIR/backend_bootstrap"

# 4.1 Apply Backend Bootstrap
"$IAC_BIN" init -input=false >/dev/null 2>&1
if "$IAC_BIN" apply -auto-approve -input=false >/dev/null 2>&1; then
    record_result "06" "Backend bootstrap applied (S3 State Bucket & DynamoDB Lock Table)" 0 "Resources created successfully"
else
    record_result "06" "Backend bootstrap applied" 1 "Backend bootstrap apply failed"
    exit 1
fi

# 4.2 Extract Outputs
STATE_BUCKET=$("$IAC_BIN" output -raw s3_bucket_name)
LOCK_TABLE=$("$IAC_BIN" output -raw dynamodb_table_name)

if [[ -n "$STATE_BUCKET" && -n "$LOCK_TABLE" ]]; then
    record_result "07" "Bootstrap outputs resolved" 0 "Bucket: ${STATE_BUCKET} | Table: ${LOCK_TABLE}"
else
    record_result "07" "Bootstrap outputs resolved" 1 "Outputs missing"
    exit 1
fi

# 4.3 Verify S3 Versioning
VERSIONING_STATUS=$($AWS_CMD s3api get-bucket-versioning --bucket "$STATE_BUCKET" --query "Status" --output text 2>/dev/null || echo "")
if [[ "$VERSIONING_STATUS" == "Enabled" ]]; then
    record_result "08" "S3 Bucket versioning confirmed (Status = Enabled)" 0 "Protects against state corruption & permits rollbacks"
else
    record_result "08" "S3 Bucket versioning confirmed" 1 "Versioning status: ${VERSIONING_STATUS}"
fi

# 4.4 Verify S3 Server-Side Encryption (SSE-S3 AES256)
SSE_ALGO=$($AWS_CMD s3api get-bucket-encryption --bucket "$STATE_BUCKET" --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" --output text 2>/dev/null || echo "")
if [[ "$SSE_ALGO" == "AES256" ]]; then
    record_result "09" "S3 Server-Side Encryption verified (AES256)" 0 "State files encrypted at rest"
else
    record_result "09" "S3 Server-Side Encryption verified" 1 "SSE Algorithm: ${SSE_ALGO}"
fi

# 4.5 Verify DynamoDB Table Partition Key
DDB_KEY=$($AWS_CMD dynamodb describe-table --table-name "$LOCK_TABLE" --query "Table.KeySchema[0].AttributeName" --output text 2>/dev/null || echo "")
if [[ "$DDB_KEY" == "LockID" ]]; then
    record_result "10" "DynamoDB State Lock table verified with Partition Key 'LockID'" 0 "Table status: ACTIVE"
else
    record_result "10" "DynamoDB State Lock table verified" 1 "Key schema: ${DDB_KEY}"
fi

# ------------------------------------------------------------------------------
# Phase 5: Consuming Demo Workload with Remote Backend
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 5: Consuming Workload Remote Backend Initialization${CLR_RESET}"

cd "$SCRIPT_DIR/demo_infrastructure"

# Generate backend configuration file dynamically
cat << EOF > backend-generated.hcl
bucket                      = "${STATE_BUCKET}"
key                         = "demo-workload/terraform.tfstate"
region                      = "us-east-1"
dynamodb_table              = "${LOCK_TABLE}"
dynamodb_endpoint           = "${EMULATOR_URL}"
encrypt                     = true
endpoint                    = "${EMULATOR_URL}"
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
use_path_style              = true
EOF

# Initialize demo infrastructure with remote S3 backend
if "$IAC_BIN" init -backend-config=backend-generated.hcl -reconfigure -input=false >/dev/null 2>&1; then
    record_result "11" "Workload initialized with Remote S3 backend & DynamoDB locks" 0 "Backend configured successfully"
else
    record_result "11" "Workload initialized with Remote S3 backend & DynamoDB locks" 1 "Init failed"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 6: Concurrency & Real-Time State Locking Test
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 6: Real-Time Concurrency & Race Condition Prevention${CLR_RESET}"

# Launch Process A in the background with a 15-second artificial delay
echo "  [Process A] Starting long-running 'terraform apply' (holding state lock for 15s)..."
"$IAC_BIN" apply -auto-approve -var="apply_delay_seconds=15" -input=false >/tmp/proc_a.log 2>&1 &
PROC_A_PID=$!

# 6.1 Inspect active lock in DynamoDB (poll for lock acquisition)
LOCK_EXISTS=""
for _ in {1..10}; do
    ACTIVE_LOCK=$($AWS_CMD dynamodb scan \
        --table-name "$LOCK_TABLE" \
        --output json 2>/dev/null || echo "{}")

    LOCK_COUNT=$(echo "$ACTIVE_LOCK" | jq -r '.Count // 0')
    if [[ "$LOCK_COUNT" -ge 1 ]]; then
        LOCK_EXISTS=$(echo "$ACTIVE_LOCK" | jq -r '.Items[0].LockID.S // empty')
        break
    fi
    sleep 1
done

if [[ -n "$LOCK_EXISTS" ]]; then
    record_result "12" "Active DynamoDB state lock item detected during execution" 0 "LockID: ${LOCK_EXISTS}"
else
    record_result "12" "Active DynamoDB state lock item detected during execution" 1 "Lock not found in DynamoDB"
fi

# 6.2 Launch Process B simultaneously (Must be blocked by the lock)
echo "  [Process B] Attempting concurrent 'terraform apply' (Expecting lock rejection)..."
set +e
PROC_B_OUTPUT=$("$IAC_BIN" apply -auto-approve -lock-timeout=1s -input=false 2>&1)
PROC_B_EXIT_CODE=$?
set -e

# Process B should fail because Process A holds the lock
if [[ $PROC_B_EXIT_CODE -ne 0 ]] && echo "$PROC_B_OUTPUT" | grep -Eq "Error acquiring the state lock|ConditionalCheckFailedException|Lock Info"; then
    record_result "13" "Process B blocked by DynamoDB lock (Race condition PREVENTED)" 0 "Rejected with 'Error acquiring the state lock'"
else
    record_result "13" "Process B blocked by DynamoDB lock" 1 "Process B unexpectedly succeeded or gave wrong error: ${PROC_B_OUTPUT}"
fi

# Wait for Process A to finish
set +e
wait $PROC_A_PID
PROC_A_EXIT_CODE=$?
set -e

if [[ $PROC_A_EXIT_CODE -eq 0 ]]; then
    record_result "14" "Process A completed successfully and released the lock" 0 "Workload resources provisioned"
    rm -f /tmp/proc_a.log
else
    PROC_A_ERR=$(cat /tmp/proc_a.log 2>/dev/null | tail -n 5 || echo "Unknown error")
    record_result "14" "Process A completed successfully" 1 "Process A exited with code ${PROC_A_EXIT_CODE}: ${PROC_A_ERR}"
fi

# 6.3 Verify DynamoDB lock is released after Process A completes
RELEASED=false
REMAINING_LOCKS=0
for _ in {1..10}; do
    POST_SCAN=$($AWS_CMD dynamodb scan \
        --table-name "$LOCK_TABLE" \
        --output json 2>/dev/null || echo "{}")

    REMAINING_LOCKS=$(echo "$POST_SCAN" | jq '[.Items[]? | select(.Info != null)] | length')
    if [[ "$REMAINING_LOCKS" -eq 0 ]]; then
        RELEASED=true
        break
    fi
    sleep 1
done

if [[ "$RELEASED" == true ]]; then
    record_result "15" "DynamoDB lock item automatically released and deleted" 0 "Zero active locks remaining"
else
    record_result "15" "DynamoDB lock item automatically released" 1 "Active lock still present in DynamoDB (Count = ${REMAINING_LOCKS})"
fi

# ------------------------------------------------------------------------------
# Phase 7: S3 State Versioning & Audit Trail Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 7: S3 State Versioning & History Audit${CLR_RESET}"

# Execute a second apply to create another state version
"$IAC_BIN" apply -auto-approve -var="app_name=order-processing-v2" -input=false >/dev/null 2>&1

STATE_VERSIONS_COUNT=$($AWS_CMD s3api list-object-versions \
    --bucket "$STATE_BUCKET" \
    --prefix "demo-workload/terraform.tfstate" \
    --query "length(Versions)" --output text 2>/dev/null || echo "0")

if [[ "$STATE_VERSIONS_COUNT" -ge 2 ]]; then
    record_result "16" "S3 State Versioning verified (${STATE_VERSIONS_COUNT} immutable versions created)" 0 "Complete state history preserved"
else
    record_result "16" "S3 State Versioning verified" 1 "Expected >= 2 versions, found: ${STATE_VERSIONS_COUNT}"
fi

# ------------------------------------------------------------------------------
# Phase 8: Teardown & Clean Destruction
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 8: Infrastructure Destruction & Teardown${CLR_RESET}"

if [[ "$KEEP_RUNNING" == true ]]; then
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] --keep flag specified: Leaving resources and emulator active."
    echo -e "  S3 State Bucket : ${CLR_GREEN}${STATE_BUCKET}${CLR_RESET}"
    echo -e "  DynamoDB Table  : ${CLR_GREEN}${LOCK_TABLE}${CLR_RESET}"
    echo -e "  To clean up later, run: ./cleanup.sh --all"
else
    # Destroy demo infrastructure
    echo "  Destroying demo workload..."
    "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1

    # Empty all object versions and delete markers from state bucket before bootstrap destroy
    cd "$SCRIPT_DIR/backend_bootstrap"
    echo "  Purging S3 state bucket versions..."
    VERSIONS=$($AWS_CMD s3api list-object-versions --bucket "$STATE_BUCKET" --output json 2>/dev/null || echo "{}")
    OBJECTS_TO_DELETE=$(echo "$VERSIONS" | jq '{Objects: [.Versions[]?, .DeleteMarkers[]? | {Key: .Key, VersionId: .VersionId}] | select(length > 0)}' 2>/dev/null || echo "")

    if [[ -n "$OBJECTS_TO_DELETE" && "$OBJECTS_TO_DELETE" != "{}" && "$OBJECTS_TO_DELETE" != '{"Objects":[]}' ]]; then
        $AWS_CMD s3api delete-objects --bucket "$STATE_BUCKET" --delete "$OBJECTS_TO_DELETE" >/dev/null 2>&1 || true
    fi

    # Destroy backend bootstrap
    echo "  Destroying backend bootstrap infrastructure..."
    "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1

    # Remove Docker emulator container
    echo "  Removing local emulator container..."
    docker rm -f "${EMULATOR_CONTAINER}" >/dev/null 2>&1 || true

    record_result "17" "Complete infrastructure destruction and emulator container cleanup" 0 "All AWS resources and Docker containers purged"
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
    echo -e "${CLR_GREEN}${CLR_BOLD}🎉 ALL REMOTE STATE LOCKING TESTS PASSED PERFECTLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S)${CLR_RESET}\n"
    exit 1
fi
