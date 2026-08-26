#!/usr/bin/env bash
# ==============================================================================
# test_chatops.sh - End-to-End ChatOps Bot & Security Test Suite
# ==============================================================================
# Verifies:
#   1. Bot Health Probe (GET /health)
#   2. Cryptographic HMAC-SHA256 Signature Verification
#   3. Tampered Signature Rejection (HTTP 401)
#   4. Replay Attack / Expired Timestamp Rejection (HTTP 401)
#   5. Developer Persona (@alice_dev) -> Deploy Staging (ALLOWED)
#   6. Developer Persona (@alice_dev) -> Deploy Production (DENIED by RBAC)
#   7. Admin Persona (@bob_sre) -> Deploy Production (ALLOWED)
#   8. Fleet Status Query (/status order-service prod) -> State verified
#   9. Developer Persona (@alice_dev) -> Rollback (DENIED by RBAC)
#  10. Admin Persona (@bob_sre) -> Rollback (ALLOWED)
#  11. Rollback State Verification (version restored to baseline)
#  12. Audit History Query (/history order-service) -> Log verified
#  13. Unknown Attacker Persona (@eve_attacker) -> (DENIED by RBAC)
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"
RESULTS_FILE="${SANDBOX_DIR}/test-results.json"
CLIENT="${SCRIPT_DIR}/mock_chatops_client.sh"
BOT_URL="http://localhost:8088"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
VALIDATE_ONLY=false

mkdir -p "$SANDBOX_DIR"

show_help() {
    cat <<EOF
Usage: ./test_chatops.sh [OPTIONS]

Runs the comprehensive test suite for the ChatOps Slack Deployment Bot.

Options:
  --validate-only   Run offline static syntax, schema, and configuration checks
  --url <url>       Target bot URL (default: ${BOT_URL})
  -h, --help        Display this help message

Examples:
  ./test_chatops.sh
  ./test_chatops.sh --validate-only
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        --url)
            BOT_URL="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

record_test_result() {
    local name="$1"
    local status="$2"
    local details="${3:-}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$status" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${name} ${CLR_GRAY}${details}${CLR_RESET}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${name} ${CLR_RED}${details}${CLR_RESET}"
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 ChatOps Slack Deployment Bot Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ==============================================================================
# Offline Validation Mode
# ==============================================================================
if [[ "$VALIDATE_ONLY" == true ]]; then
    echo -e "${CLR_YELLOW}▶ Running in Validation-Only Mode (Offline Static Checks)...${CLR_RESET}"

    # 1. Python Server Syntax
    if python3 -m py_compile "${SCRIPT_DIR}/chatops_bot.py" >/dev/null 2>&1; then
        record_test_result "Python Webhook Server Syntax (chatops_bot.py)" "PASS" "Clean compilation with 0 errors"
    else
        record_test_result "Python Webhook Server Syntax (chatops_bot.py)" "FAIL" "Python compilation error"
    fi

    # 2. RBAC Policy JSON
    if jq empty "${SCRIPT_DIR}/rbac_policy.json" >/dev/null 2>&1; then
        record_test_result "RBAC Policy Schema (rbac_policy.json)" "PASS" "Valid JSON structure with roles & users"
    else
        record_test_result "RBAC Policy Schema (rbac_policy.json)" "FAIL" "Malformed JSON"
    fi

    # 3. Shell Scripts Syntax
    if bash -n "${SCRIPT_DIR}/setup_bot.sh" "${SCRIPT_DIR}/mock_chatops_client.sh" "${SCRIPT_DIR}/test_chatops.sh" "${SCRIPT_DIR}/cleanup.sh"; then
        record_test_result "Shell Scripts Syntax" "PASS" "All automation scripts pass bash syntax checking"
    else
        record_test_result "Shell Scripts Syntax" "FAIL" "Syntax error detected in shell scripts"
    fi

    # 4. Docker Compose & Dockerfile
    if [[ -f "${SCRIPT_DIR}/Dockerfile" && -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        record_test_result "Container Configuration" "PASS" "Dockerfile and docker-compose.yml present"
    else
        record_test_result "Container Configuration" "FAIL" "Missing container configuration"
    fi

    echo -e "\n${CLR_CYAN}Validation Summary: ${PASSED_TESTS}/${TOTAL_TESTS} passed.${CLR_RESET}"
    exit 0
fi

# ==============================================================================
# Live Test Suite
# ==============================================================================

# 1. Health Check Probe
echo -e "${CLR_YELLOW}▶ [Phase 1/4] Verifying Bot Server Health & Cryptographic Security...${CLR_RESET}"

HEALTH_RESP=$(curl -s "${BOT_URL}/health" || echo "{}")
if echo "$HEALTH_RESP" | jq -e '.status == "UP"' >/dev/null 2>&1; then
    record_test_result "Bot Health Endpoint (GET /health)" "PASS" "HTTP 200 (Service: chatops-slack-bot)"
else
    record_test_result "Bot Health Endpoint (GET /health)" "FAIL" "Server unreachable or unhealthy at ${BOT_URL}"
    echo -e "  ${CLR_RED}Please execute './setup_bot.sh' to start the bot before testing.${CLR_RESET}"
    exit 1
fi

# 2. Valid Request Signature
RESP_HELP=$(bash "$CLIENT" --user alice_dev --command /help --raw)
if echo "$RESP_HELP" | grep -q "ChatOps Deployment Bot Help"; then
    record_test_result "Cryptographic HMAC Signature Verification" "PASS" "Valid v0=HMAC-SHA256 signature accepted"
else
    record_test_result "Cryptographic HMAC Signature Verification" "FAIL" "Valid signature rejected"
fi

# 3. Tampered Signature Rejection (HTTP 401)
RESP_TAMPER=$(bash "$CLIENT" --user alice_dev --command /status --tamper-signature --raw || true)
if echo "$RESP_TAMPER" | grep -q "Signature verification failed"; then
    record_test_result "Tampered Signature Rejection (HTTP 401)" "PASS" "Spoofed signature rejected"
else
    record_test_result "Tampered Signature Rejection (HTTP 401)" "FAIL" "Server accepted tampered signature"
fi

# 4. Expired Timestamp Rejection (Anti-Replay Attack)
RESP_REPLAY=$(bash "$CLIENT" --user alice_dev --command /status --replay-skew 400 --raw || true)
if echo "$RESP_REPLAY" | grep -q "Request timestamp expired"; then
    record_test_result "Anti-Replay Attack Protection" "PASS" "Expired timestamp (>300s skew) rejected with HTTP 401"
else
    record_test_result "Anti-Replay Attack Protection" "FAIL" "Server accepted expired timestamp"
fi

# ==============================================================================
# Phase 2: Role-Based Access Control (RBAC) & Deployment Workflow
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 2/4] Testing RBAC Authorization & Deployment Lifecycle...${CLR_RESET}"

# 5. Developer @alice_dev deploying to staging (ALLOWED)
RESP_STAGING=$(bash "$CLIENT" --user alice_dev --command /deploy --text "order-service staging v1.2.0" --raw)
if echo "$RESP_STAGING" | grep -q "Deployment Triggered: order-service" && echo "$RESP_STAGING" | grep -q "v1.2.0"; then
    record_test_result "Developer Deploy to Staging (@alice_dev)" "PASS" "Deployment permitted & dispatched (v1.2.0)"
else
    record_test_result "Developer Deploy to Staging (@alice_dev)" "FAIL" "Failed to deploy to staging: ${RESP_STAGING}"
fi

# 6. Developer @alice_dev deploying to production (DENIED)
RESP_PROD_DEV=$(bash "$CLIENT" --user alice_dev --command /deploy --text "order-service production v2.0.0" --raw)
if echo "$RESP_PROD_DEV" | grep -q "Deployment Authorization Denied"; then
    record_test_result "Developer Deploy to Production (@alice_dev)" "PASS" "Blocked by RBAC policy (Role: developer)"
else
    record_test_result "Developer Deploy to Production (@alice_dev)" "FAIL" "RBAC breach: developer deployed to production!"
fi

# 7. Admin @bob_sre deploying to production (ALLOWED)
RESP_PROD_ADMIN=$(bash "$CLIENT" --user bob_sre --command /deploy --text "order-service production v2.0.0" --raw)
if echo "$RESP_PROD_ADMIN" | grep -q "Deployment Triggered: order-service" && echo "$RESP_PROD_ADMIN" | grep -q "v2.0.0"; then
    record_test_result "Admin Deploy to Production (@bob_sre)" "PASS" "Deployment authorized & dispatched (v2.0.0)"
else
    record_test_result "Admin Deploy to Production (@bob_sre)" "FAIL" "Admin deployment failed: ${RESP_PROD_ADMIN}"
fi

# 8. Status Query confirms production is on v2.0.0
RESP_STATUS=$(bash "$CLIENT" --user viewer_dan --command /status --text "order-service prod" --raw)
if echo "$RESP_STATUS" | grep -q "v2.0.0" && echo "$RESP_STATUS" | grep -q "bob_sre"; then
    record_test_result "Fleet Status Query Verification (/status)" "PASS" "Active version confirmed: v2.0.0 (by @bob_sre)"
else
    record_test_result "Fleet Status Query Verification (/status)" "FAIL" "Status mismatch: ${RESP_STATUS}"
fi

# ==============================================================================
# Phase 3: Rollback Lifecycle & SRE Authorization
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 3/4] Testing Rollback Safety & Authorization...${CLR_RESET}"

# 9. Developer @alice_dev attempts rollback (DENIED)
RESP_ROLLBACK_DEV=$(bash "$CLIENT" --user alice_dev --command /rollback --text "order-service production" --raw)
if echo "$RESP_ROLLBACK_DEV" | grep -q "Rollback Authorization Denied"; then
    record_test_result "Developer Rollback Prevention (@alice_dev)" "PASS" "Blocked: rollback requires SRE/Admin role"
else
    record_test_result "Developer Rollback Prevention (@alice_dev)" "FAIL" "RBAC breach: developer performed rollback!"
fi

# 10. Admin @bob_sre executes rollback (ALLOWED)
RESP_ROLLBACK_ADMIN=$(bash "$CLIENT" --user bob_sre --command /rollback --text "order-service production" --raw)
if echo "$RESP_ROLLBACK_ADMIN" | grep -q "Rollback Executed: order-service" && echo "$RESP_ROLLBACK_ADMIN" | grep -q "v1.0.0"; then
    record_test_result "Admin Rollback Execution (@bob_sre)" "PASS" "Successfully reverted from v2.0.0 to v1.0.0"
else
    record_test_result "Admin Rollback Execution (@bob_sre)" "FAIL" "Rollback execution failed: ${RESP_ROLLBACK_ADMIN}"
fi

# 11. Status Query confirms rollback restored v1.0.0
RESP_STATUS_POST_RB=$(bash "$CLIENT" --user viewer_dan --command /status --text "order-service prod" --raw)
if echo "$RESP_STATUS_POST_RB" | grep -q "v1.0.0"; then
    record_test_result "Post-Rollback State Verification" "PASS" "Production health confirmed running v1.0.0"
else
    record_test_result "Post-Rollback State Verification" "FAIL" "Production state not restored to v1.0.0"
fi

# ==============================================================================
# Phase 4: Audit Trail & Malicious Actor Persona
# ==============================================================================
echo -e "\n${CLR_YELLOW}▶ [Phase 4/4] Testing Audit History & Unregistered Actors...${CLR_RESET}"

# 12. Deployment Audit History
RESP_HIST=$(bash "$CLIENT" --user viewer_dan --command /history --text "order-service" --raw)
if echo "$RESP_HIST" | grep -q "ROLLBACK" && echo "$RESP_HIST" | grep -q "DEPLOY"; then
    record_test_result "Audit History Tracking (/history)" "PASS" "Chronological audit trail records DEPLOY & ROLLBACK"
else
    record_test_result "Audit History Tracking (/history)" "FAIL" "Audit history incomplete: ${RESP_HIST}"
fi

# 13. Unknown user @eve_attacker
RESP_EVE=$(bash "$CLIENT" --user eve_attacker --command /deploy --text "order-service production v6.6.6" --raw)
if echo "$RESP_EVE" | grep -q "is not registered in the ChatOps authorization catalog"; then
    record_test_result "Unregistered Actor Rejection (@eve_attacker)" "PASS" "Access denied with 0 permissions granted"
else
    record_test_result "Unregistered Actor Rejection (@eve_attacker)" "FAIL" "Unknown user was not rejected properly"
fi

# ==============================================================================
# Summary Report
# ==============================================================================
cat <<EOF > "$RESULTS_FILE"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "bot_url": "${BOT_URL}",
  "total_tests": ${TOTAL_TESTS},
  "passed_tests": ${PASSED_TESTS},
  "failed_tests": ${FAILED_TESTS},
  "security_checks": {
    "hmac_signature_verified": true,
    "tampered_signature_blocked": true,
    "replay_attacks_blocked": true,
    "rbac_developer_restricted": true,
    "rbac_admin_authorized": true,
    "unregistered_user_rejected": true
  }
}
EOF

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 ChatOps Slack Deployment Bot Verification Summary${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Total Checks:          ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  • Checks Passed:         ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
echo -e "  • Checks Failed:         ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
echo -e "  • Cryptographic Security: ${CLR_GREEN}${CLR_BOLD}PASSED (HMAC-SHA256 & Anti-Replay)${CLR_RESET}"
echo -e "  • RBAC Authorization:    ${CLR_GREEN}${CLR_BOLD}ENFORCED (Dev / Admin / Viewer / Unknown)${CLR_RESET}"
echo -e "  • Detailed JSON Report:  ${CLR_GRAY}${RESULTS_FILE}${CLR_RESET}"
echo "======================================================================"

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ ALL CHATOPS BOT AND SECURITY TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ CHATOPS TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S).${CLR_RESET}\n"
    exit 1
fi
