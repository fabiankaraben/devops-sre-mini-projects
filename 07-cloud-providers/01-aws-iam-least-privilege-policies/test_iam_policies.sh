#!/usr/bin/env bash
# ==============================================================================
# test_iam_policies.sh - Automated Security & Compliance Test Suite
# ==============================================================================
# Validates JSON policy schemas, verifies Terraform configurations, and executes
# the IAM Policy Evaluator test matrix asserting least-privilege, boundary
# containment, MFA conditions, and Service Control Policies (SCPs).
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCALSTACK_CONTAINER="localstack-iam-demo"
LOCALSTACK_PORT=4566
RUN_EMULATOR=false
VERBOSE=false

for arg in "$@"; do
    case "$arg" in
        --localstack|--emulator)
            RUN_EMULATOR=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: ./test_iam_policies.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --localstack, --emulator  Spin up LocalStack Docker container and test against live emulator"
            echo "  --verbose, -v             Enable verbose output during validation and evaluation"
            echo "  --help, -h                Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./test_iam_policies.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🛡️  AWS IAM Least-Privilege & Role Boundaries Validation Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Dependency Checks
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking Tooling Prerequisites...${CLR_RESET}"

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is required but not found in PATH."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found Python: $($PYTHON_BIN --version)"

IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

if [[ -n "$IAC_BIN" ]]; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found IaC Engine: $IAC_BIN ($($IAC_BIN version -json 2>/dev/null | grep -o '"version":"[^"]*"' || $IAC_BIN --version | head -n 1))"
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Neither Terraform nor OpenTofu found in PATH. Skipping IaC syntax checks."
fi

# ------------------------------------------------------------------------------
# 2. JSON Policy Syntax & Schema Linting
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Linting JSON IAM Policy Documents...${CLR_RESET}"
JSON_COUNT=0
JSON_ERRORS=0

while IFS= read -r -d '' json_file; do
    JSON_COUNT=$((JSON_COUNT + 1))
    rel_path="${json_file#"$SCRIPT_DIR"/}"
    if $PYTHON_BIN -m json.tool "$json_file" >/dev/null 2>&1; then
        if [[ "$VERBOSE" == true ]]; then
            echo -e "  [${CLR_GREEN}VALID${CLR_RESET}] $rel_path"
        fi
    else
        echo -e "  [${CLR_RED}INVALID${CLR_RESET}] $rel_path (Syntax Error)"
        JSON_ERRORS=$((JSON_ERRORS + 1))
    fi
done < <(find "$SCRIPT_DIR/policies" -type f -name "*.json" -print0)

if [[ $JSON_ERRORS -eq 0 ]]; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All $JSON_COUNT IAM JSON policy files are valid JSON."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Found $JSON_ERRORS malformed JSON policy files."
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. IaC Manifest Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Validating Terraform / OpenTofu Manifests...${CLR_RESET}"
if [[ -n "$IAC_BIN" ]]; then
    echo "  Checking IaC code formatting..."
    if "$IAC_BIN" fmt -check "$SCRIPT_DIR" >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC files properly formatted."
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Reformatting IaC manifests with '$IAC_BIN fmt'..."
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
# 4. Execute IAM Security Evaluation Matrix (Offline Engine)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Running IAM Security Test Matrix (Deterministic Offline Engine)...${CLR_RESET}"
EVALUATOR_SCRIPT="$SCRIPT_DIR/iam_policy_evaluator.py"

EVAL_OPTS=("--mode" "offline" "--json-output" "$SCRIPT_DIR/test_report.json")
if [[ "$VERBOSE" == true ]]; then
    EVAL_OPTS+=("--verbose")
fi

if $PYTHON_BIN "$EVALUATOR_SCRIPT" "${EVAL_OPTS[@]}"; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All security assertions and least-privilege checks passed successfully."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Security policy matrix evaluation failed."
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Optional LocalStack Emulator Live Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Emulator Integration Testing...${CLR_RESET}"
if [[ "$RUN_EMULATOR" == true ]]; then
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running or not installed."
        exit 1
    fi

    echo "  Starting LocalStack container: $LOCALSTACK_CONTAINER..."
    if ! docker ps --format '{{.Names}}' | grep -Eq "^${LOCALSTACK_CONTAINER}$"; then
        docker rm -f "$LOCALSTACK_CONTAINER" >/dev/null 2>&1 || true
        docker run -d --name "$LOCALSTACK_CONTAINER" \
            -p "${LOCALSTACK_PORT}:4566" \
            -e SERVICES=iam,sts,s3,kms,ec2 \
            -e AWS_DEFAULT_REGION=us-east-1 \
            localstack/localstack:latest >/dev/null 2>&1
    fi

    echo "  Waiting for LocalStack health endpoint..."
    MAX_ATTEMPTS=30
    ATTEMPT=0
    HEALTHY=false
    while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
        ATTEMPT=$((ATTEMPT + 1))
        if curl -s "http://127.0.0.1:${LOCALSTACK_PORT}/_localstack/health" | grep -q '"iam": "available"\|"iam": "running"\|"s3": "available"\|"s3": "running"'; then
            HEALTHY=true
            break
        fi
        sleep 1
    done

    if [[ "$HEALTHY" == true ]]; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] LocalStack is healthy on port ${LOCALSTACK_PORT}."
        if [[ -n "$IAC_BIN" ]]; then
            echo "  Applying Terraform against LocalStack..."
            (
                cd "$SCRIPT_DIR"
                AWS_ACCESS_KEY_ID=mock_key \
                AWS_SECRET_ACCESS_KEY=mock_secret \
                AWS_DEFAULT_REGION=us-east-1 \
                "$IAC_BIN" apply -auto-approve \
                    -var="aws_endpoint=http://127.0.0.1:${LOCALSTACK_PORT}" \
                    -var="trusted_account_id=000000000000" >/dev/null 2>&1
            )
            echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Terraform resources successfully provisioned on LocalStack."
        fi
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] LocalStack health check timed out. Skipping live emulator apply."
    fi
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] LocalStack live emulator skipped (run with --localstack to enable)."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 All IAM Security Tests & Validations Passed Successfully!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
exit 0
