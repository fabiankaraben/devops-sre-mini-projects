#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - End-to-End Automated Test Runner for Structured JSON Logging
# ==============================================================================
# 1. Checks prerequisites (Docker, Docker Compose, Python 3).
# 2. Builds container image and starts Docker Compose stack.
# 3. Awaits container healthcheck readiness.
# 4. Executes multi-scenario synthetic workloads and error injections.
# 5. Captures container logs and validates 100% schema compliance.
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
echo "  🚀 Structured JSON Logging Framework - Automated Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running. Please start OrbStack or Docker Desktop."
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
# 2. Build Image & Start Containers
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building & Launching Microservice Container...${CLR_RESET}"

$COMPOSE_CMD build >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container image built successfully."

$COMPOSE_CMD up -d --remove-orphans
echo "  Awaiting container healthcheck readiness..."

MAX_RETRIES=20
RETRY_COUNT=0
HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    APP_STATUS="$(docker inspect --format='{{json .State.Health.Status}}' structured-logging-app 2>/dev/null || echo '"starting"')"

    if [[ "$APP_STATUS" == '"healthy"' ]]; then
        HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 1
done

if [ "$HEALTHY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container 'structured-logging-app' is healthy on port 8000."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Container failed to become healthy within timeout."
    docker logs structured-logging-app || true
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Generate Multi-Scenario Workload & Error Injections
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Injecting Multi-Scenario Synthetic Requests...${CLR_RESET}"

BASE_URL="http://127.0.0.1:8000"

# Function to execute curl request with status report
call_endpoint() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local header="${4:-}"
    local desc="$5"

    local extra_args=()
    if [[ -n "$data" ]]; then
        extra_args+=(-H "Content-Type: application/json" -d "$data")
    fi
    if [[ -n "$header" ]]; then
        extra_args+=(-H "$header")
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" ${extra_args[@]+"${extra_args[@]}"} "${BASE_URL}${path}" || echo "000")
    printf "  [${CLR_GREEN}%s${CLR_RESET}] %-5s %-32s - ${CLR_GRAY}%s${CLR_RESET}\n" "$http_code" "$method" "$path" "$desc"
}

# 1. Health & probes
call_endpoint "GET" "/health" "" "" "Liveness probe"
call_endpoint "GET" "/ready" "" "" "Readiness probe"
call_endpoint "GET" "/" "" "" "API root info"

# 2. Multi-step business transaction with custom correlation ID
ORDER_JSON='{"customer_id":"cust_vip_778","items":[{"sku":"SKU-LAPTOP-01","quantity":1,"unit_price":1299.99},{"sku":"SKU-MOUSE-02","quantity":2,"unit_price":29.50}],"payment_method":"credit_card"}'
call_endpoint "POST" "/api/orders" "$ORDER_JSON" "X-Correlation-ID: e18c4c70-7f22-48df-9b21-8207efb6d190" "Order creation with custom trace_id"

# 3. Cache hit & miss
call_endpoint "GET" "/api/inventory/item_101" "" "" "Cache hit query"
call_endpoint "GET" "/api/inventory/item_99?simulate_miss=true" "" "" "Cache miss query"

# 4. User 200 & 404
call_endpoint "GET" "/api/users/user_100" "" "" "User found (200)"
call_endpoint "GET" "/api/users/missing" "" "" "User not found (404)"

# 5. Batch processing with partial errors
BATCH_JSON='{"batch_name":"sync_run_01","items":[{"id":"task-1","action":"index","should_fail":false},{"id":"task-2","action":"index","should_fail":true},{"id":"task-3","action":"index","should_fail":false}]}'
call_endpoint "POST" "/api/batch/process" "$BATCH_JSON" "" "Batch processing (success + failure)"

# 6. Error & Failure Scenarios
call_endpoint "POST" "/api/checkout/payment-failure" "{}" "" "Payment gateway timeout (502)"
call_endpoint "GET" "/api/database/deadlock" "" "" "Database deadlock exception (500)"
call_endpoint "GET" "/api/external/rate-limit" "" "" "Upstream 429 Too Many Requests"
call_endpoint "GET" "/api/auth/unauthorized" "" "" "Unauthorized access security event (401)"

# ------------------------------------------------------------------------------
# 4. Run JSON Schema Validator Against Container Logs
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Validating Container Log Stream Against JSON Schema...${CLR_RESET}"

# Run schema validation script against container logs
python3 "$SCRIPT_DIR/validate_log_schema.py" --docker structured-logging-app --schema "$SCRIPT_DIR/schema/log_event_schema.json"

# ------------------------------------------------------------------------------
# 5. Summary & Verification
# ------------------------------------------------------------------------------
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 ALL TESTS PASSED! 100% Schema Compliance Verified!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "\n${CLR_CYAN}Next Steps:${CLR_RESET}"
echo -e "  • Inspect live container logs:  ${CLR_BOLD}docker logs -f structured-logging-app${CLR_RESET}"
echo -e "  • Query individual endpoints:    ${CLR_BOLD}curl -i http://localhost:8000/api/orders${CLR_RESET}"
echo -e "  • Teardown environment:          ${CLR_BOLD}./cleanup.sh --all${CLR_RESET}\n"
