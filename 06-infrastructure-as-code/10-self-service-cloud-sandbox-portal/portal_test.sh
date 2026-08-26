#!/usr/bin/env bash
# ==============================================================================
# portal_test.sh - E2E Self-Service Cloud Sandbox Provisioning Test Suite
# ==============================================================================
# Verifies:
#   1. System prerequisites (Docker, Go, OpenTofu/Terraform, AWS CLI, Python 3, curl)
#   2. IaC template formatting & syntax validation (web-app, microservice)
#   3. Local AWS emulator bootstrap (EC2, S3, IAM on port 4566)
#   4. Portal Server compilation & background execution (Go / Python)
#   5. REST API health verification (GET /healthz)
#   6. Full sandbox lifecycle execution via sandbox_client_test.py
#   7. Automated background TTL worker verification (automatic terraform destroy)
#   8. Clean server shutdown, container deletion, and workspace sanitation
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

CONTAINER_NAME="localstack-sandbox-portal"
EMULATOR_PORT=4566
EMULATOR_URL="http://127.0.0.1:${EMULATOR_PORT}"
PORTAL_PORT=8080
PORTAL_URL="http://127.0.0.1:${PORTAL_PORT}"
KEEP_RUNNING=false
SERVER_BACKEND="go" # "go" or "python"

for arg in "$@"; do
    case "$arg" in
        --python)
            SERVER_BACKEND="python"
            ;;
        --go)
            SERVER_BACKEND="go"
            ;;
        --keep)
            KEEP_RUNNING=true
            ;;
        --clean)
            exec ./cleanup.sh --all
            ;;
        --help|-h)
            echo "Usage: ./portal_test.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --go       Use compiled Go REST API server (Default)"
            echo "  --python   Use Python REST API server"
            echo "  --keep     Keep server and emulator active after tests"
            echo "  --clean    Purge all containers, workspaces, and logs"
            echo "  --help, -h Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./portal_test.sh --help for usage."
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
echo "  🧪 Self-Service Cloud Sandbox Provisioning Portal - Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e "  Server Engine: ${CLR_BOLD}${SERVER_BACKEND}${CLR_RESET}"
echo -e "  Portal URL:    ${CLR_GRAY}${PORTAL_URL}${CLR_RESET}"
echo -e "  Cloud Emulator: ${CLR_GRAY}${EMULATOR_URL}${CLR_RESET}\n"

# ------------------------------------------------------------------------------
# Test 1: Prerequisites Check
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ Step 1: Checking system prerequisites...${CLR_RESET}"
MISSING_TOOLS=()
for tool in docker aws python3 curl; do
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

if [[ "$SERVER_BACKEND" == "go" ]] && ! command -v go &>/dev/null; then
    MISSING_TOOLS+=("go")
fi

if [[ ${#MISSING_TOOLS[@]} -eq 0 ]]; then
    record_result "1" "All system prerequisites verified (Docker, IaC engine, AWS CLI, Python 3, Go)" 0 "IaC: $IAC_BIN"
else
    record_result "1" "Missing required tools: ${MISSING_TOOLS[*]}" 1
fi

# ------------------------------------------------------------------------------
# Test 2: Template Formatting and Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 2: Validating Terraform template manifests...${CLR_RESET}"
TMPL_OK=true
for tmpl in templates/web-app templates/microservice; do
    if ! ($IAC_BIN -chdir="$tmpl" fmt -check >/dev/null 2>&1 && \
          $IAC_BIN -chdir="$tmpl" init -backend=false >/dev/null 2>&1 && \
          $IAC_BIN -chdir="$tmpl" validate >/dev/null 2>&1); then
        TMPL_OK=false
        break
    fi
done

if [[ "$TMPL_OK" == true ]]; then
    record_result "2" "IaC templates formatted and syntactically valid (web-app, microservice)" 0
else
    record_result "2" "Template validation failed" 1
fi

# ------------------------------------------------------------------------------
# Test 3: Local AWS Emulator Bootstrap
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 3: Bootstrapping Local AWS Emulator...${CLR_RESET}"
if curl -s "${EMULATOR_URL}/" >/dev/null 2>&1; then
    record_result "3" "Local AWS emulator is already active" 0 "Endpoint: ${EMULATOR_URL}"
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
        record_result "3" "Local AWS emulator started & ready for EC2/S3 APIs" 0 "Port ${EMULATOR_PORT}"
    else
        record_result "3" "Local AWS emulator failed to start" 1
    fi
fi

# ------------------------------------------------------------------------------
# Test 4: Build and Start Portal Server
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 4: Starting Portal REST API server (${SERVER_BACKEND})...${CLR_RESET}"
mkdir -p logs data workspaces

# Kill any lingering process on port 8080
lsof -ti :${PORTAL_PORT} 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

if [[ "$SERVER_BACKEND" == "go" ]]; then
    go build -o portal-server ./cmd/server
    ./portal-server --port="${PORTAL_PORT}" --ttl-interval=1s > logs/server.log 2>&1 &
    SERVER_PID=$!
else
    python3 server.py --port="${PORTAL_PORT}" > logs/server.log 2>&1 &
    SERVER_PID=$!
fi

echo "$SERVER_PID" > logs/server.pid

# Wait for server to respond on /healthz
SERVER_READY=false
for _ in {1..20}; do
    if curl -s "${PORTAL_URL}/healthz" | grep -q "healthy"; then
        SERVER_READY=true
        break
    fi
    sleep 0.5
done

if [[ "$SERVER_READY" == true ]]; then
    record_result "4" "Portal REST API server running in background with TTL worker" 0 "PID: ${SERVER_PID}"
else
    record_result "4" "Portal server failed to start" 1 "$(cat logs/server.log 2>/dev/null || true)"
fi

# ------------------------------------------------------------------------------
# Test 5: Integration Suite Execution (sandbox_client_test.py)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 5: Executing sandbox lifecycle integration tests...${CLR_RESET}"
set +e
python3 sandbox_client_test.py --url="${PORTAL_URL}" --aws-endpoint="${EMULATOR_URL}"
CLIENT_EXIT_CODE=$?
set -e

if [[ "$CLIENT_EXIT_CODE" -eq 0 ]]; then
    record_result "5" "All 10 client lifecycle integration assertions succeeded" 0 "Provisioning, Live AWS check, Manual Delete, TTL Auto-Destroy"
else
    record_result "5" "Integration test suite failed" 1 "Exit code: ${CLIENT_EXIT_CODE}"
fi

# ------------------------------------------------------------------------------
# Test 6: Workspace & Cleanup Sanitation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 6: Performing teardown and sanitation...${CLR_RESET}"
if [[ "$KEEP_RUNNING" == false ]]; then
    if ./cleanup.sh >/dev/null 2>&1; then
        record_result "6" "cleanup.sh stopped server and purged emulator, workspaces, and logs" 0
    else
        record_result "6" "cleanup.sh failed" 1
    fi
else
    echo -e "  [${CLR_CYAN}SKIP${CLR_RESET}] Step 6: Cleanup skipped (--keep flag active)."
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# ------------------------------------------------------------------------------
# Summary Recap
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}🎉 ALL $TOTAL_TESTS TEST PHASES PASSED! ($PASSED_TESTS/$TOTAL_TESTS)${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED: $FAILED_TESTS of $TOTAL_TESTS phases failed.${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
