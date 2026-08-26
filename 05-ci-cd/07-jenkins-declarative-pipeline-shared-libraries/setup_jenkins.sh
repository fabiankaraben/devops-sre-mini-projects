#!/usr/bin/env bash
# ==============================================================================
# setup_jenkins.sh - Automated Jenkins Controller & Agent Provisioner
# ==============================================================================
# Automates:
#   1. Docker and Docker Compose prerequisite validation
#   2. Jenkins custom controller build (plugins + Docker CLI + JCasC)
#   3. Container startup via Docker Compose
#   4. Health polling until Jenkins HTTP 200 OK
#   5. Pre-configured credentials and pipeline verification
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
JENKINS_URL="http://localhost:8080"
TIMEOUT_SEC=180
POLL_INTERVAL=3

show_help() {
    cat <<EOF
Usage: ./setup_jenkins.sh [OPTIONS]

Builds and starts the Jenkins Controller with JCasC and dynamic Docker agent support.

Options:
  --timeout <seconds>   Maximum time to wait for Jenkins readiness (default: ${TIMEOUT_SEC})
  -h, --help            Display this help message

Examples:
  ./setup_jenkins.sh              # Start Jenkins stack and wait for readiness
  ./setup_jenkins.sh --timeout 60 # Set custom 60-second startup timeout
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            TIMEOUT_SEC="$2"
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
echo "  🚀 Jenkins Declarative Pipeline with Shared Libraries: Setup"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Verify Prerequisites
echo -e "${CLR_YELLOW}▶ [1/4] Verifying CLI prerequisites...${CLR_RESET}"
for bin in docker; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Required tool '${bin}' is not installed or not in PATH." >&2
        exit 1
    fi
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Found: ${bin} ($(command -v "$bin"))"
done

if ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Docker daemon is not running. Please start Docker." >&2
    exit 1
fi
echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Docker daemon is running."

# 2. Build & Launch Docker Compose Stack
echo -e "\n${CLR_YELLOW}▶ [2/4] Building and launching Jenkins Controller container...${CLR_RESET}"
cd "$SCRIPT_DIR"

# Ensure entrypoint has executable permissions
chmod +x "${SCRIPT_DIR}/init-jenkins.sh" 2>/dev/null || true

docker compose build
docker compose up -d

# 3. Poll Jenkins Health Endpoint
echo -e "\n${CLR_YELLOW}▶ [3/4] Waiting for Jenkins Controller readiness at ${JENKINS_URL}...${CLR_RESET}"
START_TIME=$(date +%s)
READY=false

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${JENKINS_URL}/login" || echo "000")

    echo -ne "  [Elapsed: ${ELAPSED}s] Checking Jenkins web status... (HTTP ${HTTP_STATUS})\r"

    if [[ "$HTTP_STATUS" == "200" ]]; then
        READY=true
        echo ""
        break
    fi

    if [[ "$ELAPSED" -ge "$TIMEOUT_SEC" ]]; then
        echo ""
        echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Timed out after ${TIMEOUT_SEC}s waiting for Jenkins startup." >&2
        echo "  Check container logs: docker compose logs jenkins" >&2
        exit 1
    fi

    sleep "$POLL_INTERVAL"
done

echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Jenkins Controller is online and responding."

# 4. Verify JCasC Configuration and Job Registration
echo -e "\n${CLR_YELLOW}▶ [4/4] Verifying Configuration as Code (JCasC) & Pipeline Job...${CLR_RESET}"

JOB_STATUS=$(curl -s -u admin:admin123 -o /dev/null -w "%{http_code}" "${JENKINS_URL}/job/enterprise-ci-pipeline/api/json" || echo "000")
if [[ "$JOB_STATUS" == "200" ]]; then
    echo -e "  [${CLR_GREEN}✓${CLR_RESET}] Pipeline job 'enterprise-ci-pipeline' registered and active."
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Job endpoint returned HTTP ${JOB_STATUS}. JCasC reload might still be finalizing."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 Jenkins Environment Provisioning Complete!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  ${CLR_BOLD}Jenkins Web UI Dashboard:${CLR_RESET}"
echo -e "    • URL:      ${CLR_CYAN}${JENKINS_URL}${CLR_RESET}"
echo -e "    • Username: ${CLR_CYAN}admin${CLR_RESET}"
echo -e "    • Password: ${CLR_CYAN}admin123${CLR_RESET}"
echo ""
echo -e "  ${CLR_BOLD}Pre-Configured Pipeline Job:${CLR_RESET}"
echo -e "    • Name:     ${CLR_CYAN}enterprise-ci-pipeline${CLR_RESET}"
echo -e "    • URL:      ${CLR_CYAN}${JENKINS_URL}/job/enterprise-ci-pipeline/${CLR_RESET}"
echo ""
echo -e "  ${CLR_BOLD}Next Steps:${CLR_RESET}"
echo -e "    Run the automated pipeline test suite:"
echo -e "    ${CLR_GREEN}${CLR_BOLD}./run_pipeline_test.sh${CLR_RESET}"
echo ""
