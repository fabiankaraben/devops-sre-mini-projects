#!/usr/bin/env bash
# ==============================================================================
# test_drift_detection.sh - E2E Terraform Drift Detection & Alerting Test Suite
# ==============================================================================
# Verifies:
#   1. System prerequisites (Docker, OpenTofu/Terraform, AWS CLI, Python 3, jq, curl)
#   2. Local AWS emulator bootstrap (EC2, S3, IAM on port 4566)
#   3. Terraform code formatting and schema validation
#   4. Baseline infrastructure provisioning (VPC, Subnet, SG, S3)
#   5. Clean baseline drift verification (Exit Code 0: In Sync)
#   6. Firewall ingress rule drift injection (out-of-band open port 8080)
#   7. Drift detection execution & detailed exit code handling (Exit Code 2)
#   8. Structured plan JSON analysis & Slack Block Kit payload generation
#   9. Tag modification drift injection & multi-resource detection
#  10. Automated self-healing remediation (--remediate flag)
#  11. Post-remediation in-sync validation (Exit Code 0)
#  12. Complete teardown and workspace sanitation
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

CONTAINER_NAME="localstack-drift-demo"
EMULATOR_PORT=4566
EMULATOR_URL="http://127.0.0.1:${EMULATOR_PORT}"
KEEP_RUNNING=false

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
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
            echo "Usage: ./test_drift_detection.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep     Keep emulator container and state files active after tests"
            echo "  --clean    Purge all containers, caches, and state immediately"
            echo "  --help, -h Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./test_drift_detection.sh --help for usage."
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
echo "  🧪 Terraform Drift Detection & Alerting - Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Test 1: Prerequisites Check
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 1: Checking system prerequisites...${CLR_RESET}"
MISSING_TOOLS=()
for tool in docker aws python3 jq curl; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

IAC_BIN=""
if command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
elif command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
else
    MISSING_TOOLS+=("tofu/terraform")
fi

if [[ ${#MISSING_TOOLS[@]} -eq 0 ]]; then
    IAC_VER=$($IAC_BIN version | head -n 1)
    record_result "1" "All prerequisites verified (Docker, IaC engine, AWS CLI, Python 3, jq, curl)" 0 "$IAC_VER"
else
    record_result "1" "Missing required tools: ${MISSING_TOOLS[*]}" 1
fi

# ------------------------------------------------------------------------------
# Test 2: Local AWS Emulator Bootstrap
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 2: Bootstrapping Local AWS Emulator container...${CLR_RESET}"
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
        record_result "2" "Local AWS emulator started & ready for EC2/S3 APIs" 0 "Port ${EMULATOR_PORT}"
    else
        record_result "2" "Local AWS emulator failed to start" 1
    fi
fi

# ------------------------------------------------------------------------------
# Test 3: Terraform Formatting & Syntax Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 3: Validating HCL formatting & configuration syntax...${CLR_RESET}"
if $IAC_BIN -chdir=terraform fmt -check >/dev/null 2>&1 && \
   $IAC_BIN -chdir=terraform init -backend=false >/dev/null 2>&1 && \
   $IAC_BIN -chdir=terraform validate >/dev/null 2>&1; then
    record_result "3" "HCL formatting, provider schema, and configuration validated" 0
else
    record_result "3" "HCL formatting or syntax validation failed" 1
fi

# ------------------------------------------------------------------------------
# Test 4: Baseline Infrastructure Provisioning
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 4: Provisioning baseline cloud infrastructure...${CLR_RESET}"
APPLY_OUT=$(cd terraform && $IAC_BIN apply -auto-approve -no-color 2>&1 || echo "")
if [[ "$APPLY_OUT" == *"Apply complete!"* || "$APPLY_OUT" == *"4 added"* ]]; then
    record_result "4" "Baseline resources provisioned (VPC, Subnet, Security Group, S3 Bucket)" 0
else
    record_result "4" "Baseline provisioning failed" 1 "$APPLY_OUT"
fi

# ------------------------------------------------------------------------------
# Test 5: Clean Baseline Drift Check (Zero Drift)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 5: Testing baseline drift detection (Expect Exit Code 0: IN-SYNC)...${CLR_RESET}"
set +e
./drift_detector.sh --quiet >/dev/null 2>&1
DETECTOR_CODE=$?
set -e

if [[ "$DETECTOR_CODE" -eq 0 ]]; then
    record_result "5" "Baseline verified: In-Sync with zero drift (Exit Code 0)" 0
else
    record_result "5" "Expected exit code 0 on clean baseline, got ${DETECTOR_CODE}" 1
fi

# ------------------------------------------------------------------------------
# Test 6: Ingress Security Group Drift Injection
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 6: Injecting out-of-band firewall rule (Port 8080/tcp)...${CLR_RESET}"
INJECT_OUT=$(./inject_drift.sh --scenario=security-group 2>&1 || echo "")
if [[ "$INJECT_OUT" == *"DRIFT INJECTED"* ]]; then
    record_result "6" "Out-of-band ingress rule (port 8080) injected directly via AWS API" 0
else
    record_result "6" "Failed to inject firewall drift" 1 "$INJECT_OUT"
fi

# ------------------------------------------------------------------------------
# Test 7: Firewall Drift Detection (Exit Code 2)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 7: Detecting firewall rule drift via drift_detector.sh...${CLR_RESET}"
set +e
./drift_detector.sh --quiet >/dev/null 2>&1
DRIFT_CODE=$?
set -e

if [[ "$DRIFT_CODE" -eq 2 ]]; then
    record_result "7" "Drift detector correctly returned Exit Code 2 (Drift Detected)" 0
else
    record_result "7" "Expected Exit Code 2 on drifted state, got ${DRIFT_CODE}" 1
fi

# ------------------------------------------------------------------------------
# Test 8: Plan JSON Parsing & Slack Block Kit Alert Payload
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 8: Verifying generated Slack Block Kit JSON payload...${CLR_RESET}"
if [[ -f "logs/slack_payload.json" ]]; then
    PAYLOAD_TEXT=$(cat "logs/slack_payload.json")
    if echo "$PAYLOAD_TEXT" | grep -q "Infrastructure Drift Detected" && \
       echo "$PAYLOAD_TEXT" | grep -q "aws_security_group.web_sg"; then
        record_result "8" "Slack Block Kit alert formatted with rogue ingress rule diff" 0 "logs/slack_payload.json"
    else
        record_result "8" "Slack payload missing expected drift details" 1
    fi
else
    record_result "8" "Slack payload file not found" 1
fi

# ------------------------------------------------------------------------------
# Test 9: Tag Modification Drift Injection & Multi-Resource Detection
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 9: Injecting tag drift on VPC and testing multi-resource detection...${CLR_RESET}"
./inject_drift.sh --scenario=tags >/dev/null 2>&1
set +e
./drift_detector.sh --quiet >/dev/null 2>&1
MULTI_DRIFT_CODE=$?
set -e

if [[ "$MULTI_DRIFT_CODE" -eq 2 ]] && grep -q "aws_vpc.main" logs/tfplan.json 2>/dev/null; then
    record_result "9" "Multi-resource drift detected across Security Group and VPC tags" 0
else
    record_result "9" "Multi-resource drift detection failed" 1
fi

# ------------------------------------------------------------------------------
# Test 10: Automated Self-Healing Remediation (--remediate)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 10: Executing automated drift remediation (--remediate)...${CLR_RESET}"
set +e
REMEDIATE_OUT=$(./drift_detector.sh --remediate 2>&1)
REMEDIATE_CODE=$?
set -e

if [[ "$REMEDIATE_CODE" -eq 0 ]] && [[ "$REMEDIATE_OUT" == *"Successfully reverted out-of-band drift"* ]]; then
    record_result "10" "Auto-remediation applied plan diff and reconciled cloud state to code" 0
else
    record_result "10" "Auto-remediation failed" 1 "$REMEDIATE_OUT"
fi

# ------------------------------------------------------------------------------
# Test 11: Post-Remediation Verification (Exit Code 0)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 11: Confirming infrastructure is in-sync post-remediation...${CLR_RESET}"
set +e
./drift_detector.sh --quiet >/dev/null 2>&1
POST_CODE=$?
set -e

if [[ "$POST_CODE" -eq 0 ]]; then
    record_result "11" "Post-remediation state confirmed strictly In-Sync (Exit Code 0)" 0
else
    record_result "11" "Infrastructure still drifted post-remediation (Code: ${POST_CODE})" 1
fi

# ------------------------------------------------------------------------------
# Test 12: Workspace Sanitation & Teardown
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 12: Running cleanup.sh...${CLR_RESET}"
if [[ "$KEEP_RUNNING" == false ]]; then
    if ./cleanup.sh >/dev/null 2>&1; then
        record_result "12" "cleanup.sh purged emulator container, state files, and logs" 0
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
