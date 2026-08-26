#!/usr/bin/env bash
# ==============================================================================
# drift_detector.sh - Automated Terraform / OpenTofu Drift Detection Engine
# ==============================================================================
# Executes speculative planning with -detailed-exitcode, parses out-of-band diffs
# into structured JSON, triggers Slack notifications, and offers self-healing.
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
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
LOGS_DIR="${SCRIPT_DIR}/logs"

mkdir -p "$LOGS_DIR"

PLAN_BINARY="${LOGS_DIR}/tfplan.binary"
PLAN_JSON="${LOGS_DIR}/tfplan.json"
SLACK_PAYLOAD="${LOGS_DIR}/slack_payload.json"
LOG_FILE="${LOGS_DIR}/drift_detector.log"

REMEDIATE=false
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
ENV_NAME="production"
QUIET=false

for arg in "$@"; do
    case "$arg" in
        --remediate)
            REMEDIATE=true
            ;;
        --webhook-url=*)
            WEBHOOK_URL="${arg#*=}"
            ;;
        --env=*)
            ENV_NAME="${arg#*=}"
            ;;
        --quiet)
            QUIET=true
            ;;
        --help|-h)
            echo "Usage: ./drift_detector.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --remediate         Automatically reconcile drifted cloud resources to match code"
            echo "  --webhook-url=<URL> Post Block Kit payload to Slack webhook"
            echo "  --env=<NAME>        Target environment name (Default: production)"
            echo "  --quiet             Suppress verbose output"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./drift_detector.sh --help for usage."
            exit 1
            ;;
    esac
done

# Step 1: Detect IaC Engine (OpenTofu or Terraform)
IAC_BIN=""
if command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
elif command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
else
    echo -e "${CLR_RED}Error: Neither 'terraform' nor 'tofu' found in PATH.${CLR_RESET}"
    exit 1
fi

if [[ "$QUIET" == false ]]; then
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🔍 Automated Terraform Drift Detector & Alerting Engine"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "  IaC Engine:   ${CLR_BOLD}${IAC_BIN}${CLR_RESET}"
    echo -e "  Environment:  ${CLR_BOLD}${ENV_NAME}${CLR_RESET}"
    echo -e "  Auto-Heal:    ${CLR_BOLD}${REMEDIATE}${CLR_RESET}"
    echo -e "  Log File:     ${CLR_GRAY}${LOG_FILE}${CLR_RESET}\n"
fi

# Step 2: Initialize Terraform working directory if needed
cd "$TERRAFORM_DIR"
if [[ ! -d ".terraform" ]]; then
    echo -e "${CLR_YELLOW}▶ Initializing Terraform working directory...${CLR_RESET}"
    $IAC_BIN init -no-color > "${LOG_FILE}" 2>&1 || {
        echo -e "${CLR_RED}❌ Failed to initialize Terraform.${CLR_RESET}"
        cat "${LOG_FILE}"
        exit 1
    }
fi

# Step 3: Run Plan with -detailed-exitcode
echo -e "${CLR_YELLOW}▶ [1/3] Running speculative plan (-detailed-exitcode)...${CLR_RESET}"
set +e
$IAC_BIN plan -detailed-exitcode -no-color -out="${PLAN_BINARY}" > "${LOGS_DIR}/plan_output.txt" 2>&1
PLAN_EXIT_CODE=$?
set -e

# Analyze Exit Code:
# 0 = Succeeded, diff is empty (no changes / zero drift)
# 1 = Errored
# 2 = Succeeded, there is a diff (drift detected!)

if [[ "$PLAN_EXIT_CODE" -eq 0 ]]; then
    echo -e "  [${CLR_GREEN}IN SYNC${CLR_RESET}] Zero infrastructure drift detected. Cloud state strictly matches code."
    
    # Generate in-sync plan JSON for record keeping
    $IAC_BIN show -json "${PLAN_BINARY}" > "${PLAN_JSON}" 2>/dev/null || echo '{"resource_changes":[]}' > "${PLAN_JSON}"
    
    # Notify Slack of in-sync status if webhook provided
    python3 "${SCRIPT_DIR}/slack_notifier.py" \
        --plan-json="${PLAN_JSON}" \
        --output-payload="${SLACK_PAYLOAD}" \
        --webhook-url="${WEBHOOK_URL}" \
        --environment="${ENV_NAME}" \
        --format=terminal >/dev/null 2>&1 || true

    echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ STATUS: IN-SYNC (Exit Code 0)${CLR_RESET}\n"
    exit 0

elif [[ "$PLAN_EXIT_CODE" -eq 2 ]]; then
    echo -e "  [${CLR_RED}DRIFT DETECTED${CLR_RESET}] Out-of-band cloud modifications found (Exit Code 2)!"
    
    # Step 4: Convert binary plan to JSON for analysis
    echo -e "\n${CLR_YELLOW}▶ [2/3] Parsing binary plan into structured JSON...${CLR_RESET}"
    $IAC_BIN show -json "${PLAN_BINARY}" > "${PLAN_JSON}"

    # Step 5: Format and send Slack alert
    echo -e "\n${CLR_YELLOW}▶ [3/3] Generating Slack Block Kit payload & formatting diff...${CLR_RESET}"
    set +e
    python3 "${SCRIPT_DIR}/slack_notifier.py" \
        --plan-json="${PLAN_JSON}" \
        --output-payload="${SLACK_PAYLOAD}" \
        --webhook-url="${WEBHOOK_URL}" \
        --environment="${ENV_NAME}" \
        --format=all
    NOTIFIER_STATUS=$?
    set -e

    # Step 6: Handle Auto-Remediation if requested
    if [[ "$REMEDIATE" == true ]]; then
        echo -e "\n${CLR_CYAN}${CLR_BOLD}🔧 AUTO-REMEDIATION REQUESTED${CLR_RESET}"
        echo -e "  Applying planned reconciliation to restore cloud resources to declared state..."
        
        $IAC_BIN apply -auto-approve "${PLAN_BINARY}" >> "${LOG_FILE}" 2>&1
        
        echo -e "  [${CLR_GREEN}REMEDIATED${CLR_RESET}] Successfully reverted out-of-band drift!"
        echo -e "  Verifying zero-drift state post-remediation..."
        
        set +e
        $IAC_BIN plan -detailed-exitcode -no-color >/dev/null 2>&1
        POST_REMEDIATE_CODE=$?
        set -e
        
        if [[ "$POST_REMEDIATE_CODE" -eq 0 ]]; then
            echo -e "  [${CLR_GREEN}VERIFIED${CLR_RESET}] Infrastructure is fully back in sync."
            exit 0
        else
            echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Post-remediation check returned code ${POST_REMEDIATE_CODE}."
            exit 2
        fi
    fi

    # Exit code 2 for drift detection
    exit 2

else
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Terraform plan execution failed with error code ${PLAN_EXIT_CODE}."
    cat "${LOGS_DIR}/plan_output.txt"
    exit 1
fi
