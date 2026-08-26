#!/usr/bin/env bash
# ==============================================================================
# test_proxy_permissions.sh - Automated Security Verification Test Suite
# ==============================================================================
# Validates:
#   1. Docker engine & socket prerequisites
#   2. Deployment of HAProxy Docker Socket Security Gateway
#   3. Permitted read requests (GET /_ping, /version, /info, /containers/json) -> 200 OK
#   4. Blocked container creation / root escalation (POST /containers/create) -> 403 Forbidden
#   5. Blocked remote code execution (POST /containers/.../exec) -> 403 Forbidden
#   6. Blocked denial of service attacks (POST /containers/.../kill) -> 403 Forbidden
#   7. Blocked volume snooping & manipulation (GET/POST /volumes) -> 403 Forbidden
#   8. Blocked destructive actions (DELETE /containers/...) -> 403 Forbidden
#   9. Inter-container network communication via monitoring agent
#  10. Full environment teardown and cleanup
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
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-2375}"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

FLAG_KEEP=false
FLAG_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./test_proxy_permissions.sh [OPTIONS]

Automated test suite verifying Docker Socket Security Proxy RBAC policies.

Options:
  --keep      Leave the proxy stack running after tests complete
  --clean     Stop all containers, remove networks and built images
  -h, --help  Display this help menu

Examples:
  ./test_proxy_permissions.sh          # Run full test suite with automatic teardown
  ./test_proxy_permissions.sh --keep   # Run tests and leave proxy running for manual exploration
  ./test_proxy_permissions.sh --clean  # Remove all containers and networks
EOF
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            FLAG_KEEP=true
            shift
            ;;
        --clean)
            FLAG_CLEAN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Error: Unknown option '$1'${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

cleanup_resources() {
    echo -e "${CLR_YELLOW}🧹 Cleaning up all project containers and networks...${CLR_RESET}"
    cd "$SCRIPT_DIR"
    docker compose down -v --remove-orphans 2>/dev/null || true
    docker rm -f devops-socket-proxy devops-monitoring-agent 2>/dev/null || true
    echo -e "${CLR_GREEN}✨ All project resources removed successfully.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == "true" ]]; then
    cleanup_resources
    exit 0
fi

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🛡️  Docker Socket Security Proxy Gateway - Automated Verification"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

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

query_proxy() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    if [[ -n "$body" ]]; then
        curl -s -o /dev/null -w "%{http_code}" -X "$method" "${PROXY_URL}${path}" \
            -H "Content-Type: application/json" -d "$body" 2>/dev/null || echo "000"
    else
        curl -s -o /dev/null -w "%{http_code}" -X "$method" "${PROXY_URL}${path}" 2>/dev/null || echo "000"
    fi
}

run_suite() {
    print_banner
    cd "$SCRIPT_DIR"

    # --------------------------------------------------------------------------
    # Test 1: Docker Environment & Socket Check
    # --------------------------------------------------------------------------
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        record_result "01" "Docker & Unix Socket Availability" 0 "Docker daemon is reachable at /var/run/docker.sock"
    else
        record_result "01" "Docker & Unix Socket Availability" 1 "Docker daemon is not operational"
        echo -e "${CLR_RED}Aborting suite due to missing prerequisites.${CLR_RESET}" >&2
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 2: Launch Docker Socket Security Proxy Gateway
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Deploying Security Proxy stack via Docker Compose...${CLR_RESET}"
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    if docker compose up -d socket-proxy >/dev/null 2>&1; then
        # Wait up to 10 seconds for proxy readiness
        local ready=false
        for i in {1..20}; do
            if [[ "$(query_proxy GET /_ping)" == "200" ]]; then
                ready=true
                break
            fi
            sleep 0.5
        done

        if [[ "$ready" == "true" ]]; then
            record_result "02" "Security Proxy Gateway Deployment" 0 "HAProxy initialized and listening on ${PROXY_URL}"
        else
            record_result "02" "Security Proxy Gateway Deployment" 1 "Gateway failed health check within timeout"
            exit 1
        fi
    else
        record_result "02" "Security Proxy Gateway Deployment" 1 "Docker compose up failed"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 3: Permitted Health & Metadata Endpoints (GET /_ping, /version, /info)
    # --------------------------------------------------------------------------
    local code_ping code_ver code_info
    code_ping=$(query_proxy GET /_ping)
    code_ver=$(query_proxy GET /version)
    code_info=$(query_proxy GET /info)

    if [[ "$code_ping" == "200" && "$code_ver" == "200" && "$code_info" == "200" ]]; then
        record_result "03" "Permitted Metadata Endpoints" 0 "GET /_ping (200), GET /version (200), GET /info (200)"
    else
        record_result "03" "Permitted Metadata Endpoints" 1 "Ping: $code_ping, Version: $code_ver, Info: $code_info"
    fi

    # --------------------------------------------------------------------------
    # Test 4: Permitted Container Inventory (GET /containers/json)
    # --------------------------------------------------------------------------
    local code_containers
    code_containers=$(query_proxy GET /containers/json)
    if [[ "$code_containers" == "200" ]]; then
        record_result "04" "Permitted Container Inspection" 0 "GET /containers/json returned HTTP 200 OK"
    else
        record_result "04" "Permitted Container Inspection" 1 "Expected 200, received HTTP ${code_containers}"
    fi

    # --------------------------------------------------------------------------
    # Test 5: Blocked Container Creation / Privilege Escalation (POST /containers/create)
    # --------------------------------------------------------------------------
    local code_create
    code_create=$(query_proxy POST /containers/create '{"Image":"alpine","HostConfig":{"Privileged":true,"Binds":["/:/host"]}}')
    if [[ "$code_create" == "403" ]]; then
        record_result "05" "Blocked Container Creation Attack" 0 "POST /containers/create correctly blocked (HTTP 403 Forbidden)"
    else
        record_result "05" "Blocked Container Creation Attack" 1 "Expected 403 Forbidden, received HTTP ${code_create}"
    fi

    # --------------------------------------------------------------------------
    # Test 6: Blocked Remote Code Execution (POST /containers/.../exec)
    # --------------------------------------------------------------------------
    local code_exec
    code_exec=$(query_proxy POST /containers/devops-socket-proxy/exec '{"Cmd":["whoami"]}')
    if [[ "$code_exec" == "403" ]]; then
        record_result "06" "Blocked Remote Code Execution (Exec)" 0 "POST /containers/.../exec correctly blocked (HTTP 403 Forbidden)"
    else
        record_result "06" "Blocked Remote Code Execution (Exec)" 1 "Expected 403 Forbidden, received HTTP ${code_exec}"
    fi

    # --------------------------------------------------------------------------
    # Test 7: Blocked Denial of Service Mutations (POST /containers/.../kill & /stop)
    # --------------------------------------------------------------------------
    local code_kill code_stop
    code_kill=$(query_proxy POST /containers/devops-socket-proxy/kill)
    code_stop=$(query_proxy POST /containers/devops-socket-proxy/stop)
    if [[ "$code_kill" == "403" && "$code_stop" == "403" ]]; then
        record_result "07" "Blocked Container Lifecycle Mutations" 0 "POST /kill (403) and POST /stop (403) blocked"
    else
        record_result "07" "Blocked Container Lifecycle Mutations" 1 "Kill: $code_kill, Stop: $code_stop"
    fi

    # --------------------------------------------------------------------------
    # Test 8: Blocked Volume Access & Mutation (GET/POST /volumes)
    # --------------------------------------------------------------------------
    local code_vol_get code_vol_post
    code_vol_get=$(query_proxy GET /volumes)
    code_vol_post=$(query_proxy POST /volumes/create '{"Name":"unauthorized"}')
    if [[ "$code_vol_get" == "403" && "$code_vol_post" == "403" ]]; then
        record_result "08" "Blocked Storage Volume Operations" 0 "GET /volumes (403) and POST /volumes/create (403) blocked"
    else
        record_result "08" "Blocked Storage Volume Operations" 1 "GET: $code_vol_get, POST: $code_vol_post"
    fi

    # --------------------------------------------------------------------------
    # Test 9: Blocked Destructive Deletions (DELETE /containers/...)
    # --------------------------------------------------------------------------
    local code_del
    code_del=$(query_proxy DELETE /containers/devops-socket-proxy)
    if [[ "$code_del" == "403" ]]; then
        record_result "09" "Blocked Destructive Deletions" 0 "DELETE /containers/... correctly blocked (HTTP 403 Forbidden)"
    else
        record_result "09" "Blocked Destructive Deletions" 1 "Expected 403 Forbidden, received HTTP ${code_del}"
    fi

    # --------------------------------------------------------------------------
    # Test 10: Inter-Container Monitoring Agent Integration
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Running simulated unprivileged monitoring agent container...${CLR_RESET}"
    if docker compose run --rm monitoring-agent >/dev/null 2>&1; then
        record_result "10" "Inter-Container Agent Validation" 0 "Monitoring agent safely accessed proxy over internal network"
    else
        record_result "10" "Inter-Container Agent Validation" 1 "Monitoring agent test failed"
    fi

    # --------------------------------------------------------------------------
    # Test 11: Execute Python Security Matrix Auditor
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Running Python Security Matrix Auditor...${CLR_RESET}"
    if python3 "$SCRIPT_DIR/audit_proxy.py" --host "$PROXY_HOST" --port "$PROXY_PORT" >/dev/null 2>&1; then
        record_result "11" "Python Security Policy Matrix Audit" 0 "All 12 security policy rules passed verification"
    else
        record_result "11" "Python Security Policy Matrix Audit" 1 "Audit script reported violations"
    fi

    # --------------------------------------------------------------------------
    # Test Summary & Cleanup
    # --------------------------------------------------------------------------
    echo ""
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}  📊 Test Suite Summary: ${PASSED_TESTS}/${TOTAL_TESTS} Tests Passed${CLR_RESET}"
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

    if [[ "$FLAG_KEEP" == "false" ]]; then
        cleanup_resources
    else
        echo -e "${CLR_YELLOW}ℹ️  Proxy stack retained for manual inspection as requested (--keep).${CLR_RESET}"
        echo -e "   Endpoint: ${PROXY_URL}"
    fi

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✨ All Docker Socket Security Proxy gateway tests passed!${CLR_RESET}"
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ Some tests failed. Check the logs above.${CLR_RESET}"
        exit 1
    fi
}

run_suite
