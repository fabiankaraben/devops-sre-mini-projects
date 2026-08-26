#!/usr/bin/env bash
# ==============================================================================
# mock_chatops_client.sh - High-Fidelity Mock Slack Slash Command Client
# ==============================================================================
# Simulates Slack's backend webhook dispatch with HMAC-SHA256 request signing:
#   1. Formats application/x-www-form-urlencoded payload (command, text, user_name)
#   2. Obtains current UNIX timestamp (X-Slack-Request-Timestamp)
#   3. Generates cryptographic HMAC-SHA256 signature (X-Slack-Signature: v0=...)
#   4. Sends request to ChatOps Webhook server and parses JSON response
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

# Default configuration
BOT_URL="http://localhost:8088/slack/commands"
SLACK_SIGNING_SECRET="${SLACK_SIGNING_SECRET:-supersecret_slack_signing_token_123}"
COMMAND="/status"
TEXT=""
USER_NAME="alice_dev"
CHANNEL_NAME="deployments"
TAMPER_SIG=false
REPLAY_SKEW_SEC=0
RAW_OUTPUT=false

show_help() {
    cat <<EOF
Usage: ./mock_chatops_client.sh [OPTIONS]

Sends a cryptographically signed Slack slash command to the ChatOps Bot.

Options:
  -c, --command <cmd>       Slash command (e.g. /deploy, /rollback, /status, /history, /help)
  -t, --text <args>         Command arguments (e.g. "order-service staging v1.2.0")
  -u, --user <username>     Slack user name (e.g. alice_dev, bob_sre, viewer_dan, eve_attacker)
      --channel <name>      Slack channel name (default: deployments)
      --url <url>           Target webhook URL (default: ${BOT_URL})
      --secret <secret>     Slack signing secret override
      --tamper-signature    Intentionally corrupt the HMAC signature (test security reject)
      --replay-skew <sec>   Simulate expired request timestamp (e.g. 400 for replay attack)
      --raw                 Print raw HTTP response without formatting
  -h, --help                Display this help message

Examples:
  ./mock_chatops_client.sh --user alice_dev --command /deploy --text "order-service staging v1.2.0"
  ./mock_chatops_client.sh --user bob_sre --command /deploy --text "order-service production v2.0.0"
  ./mock_chatops_client.sh --user bob_sre --command /rollback --text "order-service production"
  ./mock_chatops_client.sh --user viewer_dan --command /status
  ./mock_chatops_client.sh --tamper-signature  # Test 401 Unauthorized rejection
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--command)
            COMMAND="$2"
            shift 2
            ;;
        -t|--text)
            TEXT="$2"
            shift 2
            ;;
        -u|--user)
            USER_NAME="$2"
            shift 2
            ;;
        --channel)
            CHANNEL_NAME="$2"
            shift 2
            ;;
        --url)
            BOT_URL="$2"
            shift 2
            ;;
        --secret)
            SLACK_SIGNING_SECRET="$2"
            shift 2
            ;;
        --tamper-signature)
            TAMPER_SIG=true
            shift
            ;;
        --replay-skew)
            REPLAY_SKEW_SEC="$2"
            shift 2
            ;;
        --raw)
            RAW_OUTPUT=true
            shift
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

# URL encode helper function
urlencode() {
    local string="${1}"
    local length="${#string}"
    local encoded=""
    for (( i = 0; i < length; i++ )); do
        local c="${string:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

# 1. Build application/x-www-form-urlencoded payload
ENC_CMD=$(urlencode "$COMMAND")
ENC_TEXT=$(urlencode "$TEXT")
ENC_USER=$(urlencode "$USER_NAME")
ENC_CHAN=$(urlencode "$CHANNEL_NAME")

PAYLOAD="command=${ENC_CMD}&text=${ENC_TEXT}&user_name=${ENC_USER}&channel_name=${ENC_CHAN}&response_url=https%3A%2F%2Fhooks.slack.com%2Fcommands%2F123%2F456"

# 2. Compute Timestamp (with optional replay skew simulation)
CURRENT_EPOCH=$(date +%s)
TIMESTAMP=$((CURRENT_EPOCH - REPLAY_SKEW_SEC))

# 3. Compute Slack HMAC-SHA256 Signature: v0=HMAC_SHA256(secret, "v0:" + timestamp + ":" + body)
SIG_BASESTRING="v0:${TIMESTAMP}:${PAYLOAD}"

if command -v openssl >/dev/null 2>&1; then
    HMAC_HEX=$(printf "%s" "$SIG_BASESTRING" | openssl dgst -sha256 -hmac "$SLACK_SIGNING_SECRET" | awk '{print $NF}')
else
    # Fallback to python for HMAC calculation
    HMAC_HEX=$(python3 -c "import hmac, hashlib; print(hmac.new(b'${SLACK_SIGNING_SECRET}', b'${SIG_BASESTRING}', hashlib.sha256).hexdigest())")
fi

if [[ "$TAMPER_SIG" == true ]]; then
    SIGNATURE="v0=invalid_corrupted_signature_deadbeef1234"
else
    SIGNATURE="v0=${HMAC_HEX}"
fi

if [[ "$RAW_OUTPUT" == false ]]; then
    echo -e "${CLR_CYAN}${CLR_BOLD}[MOCK SLACK CLIENT]${CLR_RESET} Sending Slack Slash Command Request:"
    echo -e "  • Command:     ${CLR_GREEN}${COMMAND} ${TEXT}${CLR_RESET}"
    echo -e "  • User:        ${CLR_YELLOW}@${USER_NAME}${CLR_RESET}"
    echo -e "  • Timestamp:   ${TIMESTAMP} (Skew: ${REPLAY_SKEW_SEC}s)"
    echo -e "  • Signature:   ${CLR_GRAY}${SIGNATURE:0:20}...${CLR_RESET}"
    echo -e "  • Target URL:  ${BOT_URL}"
    echo "----------------------------------------------------------------------"
fi

# 4. Execute HTTP POST
HTTP_RESP=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "X-Slack-Request-Timestamp: ${TIMESTAMP}" \
    -H "X-Slack-Signature: ${SIGNATURE}" \
    -d "$PAYLOAD" \
    "$BOT_URL" 2>&1 || echo "ERROR\n000")

HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')
HTTP_CODE=$(echo "$HTTP_RESP" | tail -n 1)

if [[ "$RAW_OUTPUT" == true ]]; then
    echo "$HTTP_BODY"
    exit 0
fi

echo -e "HTTP Response Status: ${CLR_BOLD}${HTTP_CODE}${CLR_RESET}"
if command -v jq >/dev/null 2>&1 && echo "$HTTP_BODY" | jq empty >/dev/null 2>&1; then
    echo -e "${CLR_GRAY}"
    echo "$HTTP_BODY" | jq .
    echo -e "${CLR_RESET}"
else
    echo "$HTTP_BODY"
fi
