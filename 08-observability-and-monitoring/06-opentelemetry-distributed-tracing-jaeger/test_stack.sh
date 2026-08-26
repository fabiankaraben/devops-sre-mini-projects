#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Runner for OpenTelemetry & Jaeger Stack
# ==============================================================================
# 1. Verifies Docker engine, Compose, and Python 3 prerequisites.
# 2. Builds container images and starts the distributed microservice stack.
# 3. Awaits healthcheck readiness across Jaeger, Frontend, Auth, and Payment services.
# 4. Executes trace_verification.py to validate distributed spans in Jaeger API.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🔭 OpenTelemetry & Jaeger Distributed Tracing - Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker engine is running."

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker Compose not found."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose command: ${CLR_BOLD}${COMPOSE_CMD}${CLR_RESET}"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is not installed."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python environment: $(python3 --version)"

# ------------------------------------------------------------------------------
# 2. Build Container Images
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Building Microservice Container Images...${CLR_RESET}"
$COMPOSE_CMD build
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container images built successfully."

# ------------------------------------------------------------------------------
# 3. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Launching Jaeger & Microservices Stack...${CLR_RESET}"
$COMPOSE_CMD up -d --remove-orphans

echo "  Awaiting container healthcheck readiness..."
MAX_RETRIES=35
RETRY_COUNT=0
ALL_HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    JAEGER_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' jaeger-tracing 2>/dev/null || echo '"starting"')"
    AUTH_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' auth-service 2>/dev/null || echo '"starting"')"
    PAYMENT_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' payment-service 2>/dev/null || echo '"starting"')"
    FRONTEND_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' frontend-service 2>/dev/null || echo '"starting"')"

    if [[ "$JAEGER_STATUS" == '"healthy"' ]] && \
       [[ "$AUTH_STATUS" == '"healthy"' ]] && \
       [[ "$PAYMENT_STATUS" == '"healthy"' ]] && \
       [[ "$FRONTEND_STATUS" == '"healthy"' ]]; then
        ALL_HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ "$ALL_HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All 4 containers (Jaeger, Frontend, Auth, Payment) are healthy."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Stack failed to become healthy within timeout."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Execute Trace Verification Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Distributed Tracing Verification Suite...${CLR_RESET}"
python3 trace_verification.py

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All Distributed Tracing Tests Completed Successfully!${CLR_RESET}"
echo -e "🔗 Jaeger UI:     ${CLR_CYAN}http://localhost:16686${CLR_RESET}"
echo -e "🔗 Frontend API:  ${CLR_CYAN}http://localhost:8080/docs${CLR_RESET}"
echo -e "🔗 Auth API:      ${CLR_CYAN}http://localhost:8082/docs${CLR_RESET}"
echo -e "🔗 Payment API:   ${CLR_CYAN}http://localhost:8083/docs${CLR_RESET}"
echo -e "\nTo clean up all resources, execute:"
echo -e "  ${CLR_BOLD}./cleanup.sh --purge-images${CLR_RESET}\n"
