#!/usr/bin/env bash
# ==============================================================================
# setup_bot.sh - ChatOps Slack Deployment Bot Provisioner
# ==============================================================================
# Automates:
#   1. Tool verification (docker / docker compose, curl, jq)
#   2. Building and starting the ChatOps webhook server container
#   3. Polling /health until ready
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
SANDBOX_DIR="${SCRIPT_DIR}/.tmp_sandbox"
PORT=8088
BOT_URL="http://localhost:${PORT}"
MAX_WAIT_SEC=30

mkdir -p "$SANDBOX_DIR"

show_help() {
    cat <<EOF
Usage: ./setup_bot.sh [OPTIONS]

Builds and starts the ChatOps Slack Deployment Bot service.

Options:
  -p, --port <port>   Port to expose (default: ${PORT})
  -h, --help          Display this help message

Examples:
  ./setup_bot.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)
            PORT="$2"
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 ChatOps Slack Deployment Bot: Provisioning & Launch"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Verify Prerequisites
echo -e "${CLR_YELLOW}▶ [1/3] Verifying CLI prerequisites...${CLR_RESET}"
for bin in docker curl jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Required tool '${bin}' is missing." >&2
        exit 1
    fi
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Found: ${bin} ($(command -v "$bin"))"
done

if ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Docker daemon is not running." >&2
    exit 1
fi
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Docker daemon is running."

# 2. Build and Launch Stack
echo -e "\n${CLR_YELLOW}▶ [2/3] Building and starting ChatOps Bot Docker container...${CLR_RESET}"
cd "$SCRIPT_DIR"
docker compose up -d --build

# 3. Wait for Health Check
echo -e "\n${CLR_YELLOW}▶ [3/3] Waiting for ChatOps Bot health check at ${BOT_URL}/health...${CLR_RESET}"
READY=false
for ((i=1; i<=MAX_WAIT_SEC; i++)); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BOT_URL}/health" || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        READY=true
        break
    fi
    echo -ne "  [Elapsed: ${i}s] Waiting for server readiness... (HTTP ${HTTP_CODE})\r"
    sleep 1
done

if [[ "$READY" == true ]]; then
    echo -e "\n  [${CLR_GREEN}✓${CLR_RESET}] ChatOps Deployment Bot is ONLINE and healthy!"
else
    echo -e "\n  [${CLR_RED}ERROR${CLR_RESET}] Timed out waiting for bot readiness." >&2
    docker compose logs
    exit 1
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 ChatOps Deployment Bot Successfully Launched!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  • Webhook Endpoint:  ${CLR_CYAN}${BOT_URL}/slack/commands${CLR_RESET}"
echo -e "  • Health Endpoint:   ${CLR_CYAN}${BOT_URL}/health${CLR_RESET}"
echo -e "  • Signing Secret:    ${CLR_GRAY}supersecret_slack_signing_token_123${CLR_RESET}"
echo ""
echo -e "  ${CLR_BOLD}Next Steps:${CLR_RESET}"
echo -e "    Run the automated test suite:"
echo -e "    ${CLR_GREEN}${CLR_BOLD}./test_chatops.sh${CLR_RESET}"
echo ""
echo -e "    Or run interactive mock slash commands:"
echo -e "    ${CLR_CYAN}./mock_chatops_client.sh --user alice_dev --command /deploy --text \"order-service staging v1.2.0\"${CLR_RESET}"
echo ""
