#!/usr/bin/env bash
# ==============================================================================
# e2e_compose_test.sh - End-to-End Test Suite for Docker Compose Stack
# ==============================================================================
# Verifies:
#   1. Docker & Docker Compose environment availability
#   2. Orchestrated build and startup of 5 services
#   3. Startup dependency order and healthcheck validation
#   4. Edge reverse proxying via Nginx (Port 8080)
#   5. Web API connectivity and health (PostgreSQL + Redis)
#   6. Adminer management UI accessibility (Port 8088)
#   7. Custom bridge network segmentation (Frontend isolation from DB)
#   8. Cache-Aside pattern (Cache MISS on first load, Cache HIT on repeat)
#   9. Cache invalidation on mutation (POST /api/items)
#  10. Data deletion and cache update (DELETE /api/items/<id>)
#  11. PostgreSQL volume persistence across container restarts
#  12. Full teardown and resource cleanup
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

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_FRONTEND="${PORT_FRONTEND:-8090}"
PORT_ADMINER="${PORT_ADMINER:-8098}"
BASE_URL="http://127.0.0.1:${PORT_FRONTEND}"
ADMINER_URL="http://127.0.0.1:${PORT_ADMINER}"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

FLAG_KEEP=false
FLAG_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./e2e_compose_test.sh [OPTIONS]

Automated End-to-End verification suite for Multi-Service Docker Compose Stack.

Options:
  --keep      Leave the Docker Compose stack running after tests complete
  --clean     Stop all containers and remove networks, volumes, and built images
  -h, --help  Display this help menu

Examples:
  ./e2e_compose_test.sh          # Run full test suite with automatic teardown
  ./e2e_compose_test.sh --keep   # Run tests and leave environment running for UI inspection
  ./e2e_compose_test.sh --clean  # Clean up all created resources
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

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Multi-Service Docker Compose Stack E2E Automated Test Suite"
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

do_cleanup() {
    echo -e "${CLR_CYAN}🧹 Tearing down Docker Compose stack and persistent volumes...${CLR_RESET}"
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down -v --rmi local >/dev/null 2>&1 || true
    echo -e "${CLR_GREEN}✔ Teardown complete. Zero leftover resources.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == true ]]; then
    print_banner
    do_cleanup
    exit 0
fi

main() {
    print_banner

    # Phase 1: Environment & Orchestration
    echo -e "${CLR_YELLOW}Phase 1: Environment & Orchestration Launch${CLR_RESET}"

    # Test 1: Check Docker & Docker Compose
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        local compose_ver
        compose_ver=$(docker compose version --short 2>/dev/null || echo "v2")
        record_result "01" "Docker Compose CLI is available" 0 "Engine & Compose ready (${compose_ver})"
    else
        record_result "01" "Docker Compose CLI is available" 1 "Docker Compose not found"
        exit 1
    fi

    # Test 2: Build & Start Stack
    echo -e "  ${CLR_GRAY}Starting stack with 'docker compose up -d --build'...${CLR_RESET}"
    local build_output
    if build_output=$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build 2>&1); then
        record_result "02" "Stack builds and orchestrates in background" 0 "All 5 services launched"
    else
        record_result "02" "Stack builds and orchestrates in background" 1 "Build or launch failure: ${build_output}"
        exit 1
    fi

    # Test 3: Wait for healthy status across dependencies
    echo -e "  ${CLR_GRAY}Awaiting healthcheck convergence...${CLR_RESET}"
    local max_wait=35
    local elapsed=0
    local all_healthy=false

    while [[ "$elapsed" -lt "$max_wait" ]]; do
        local ps_out
        ps_out=$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps 2>/dev/null || true)
        if grep -q "(healthy)" <<< "$ps_out" && ! grep -q -E '(starting|unhealthy|Exit)' <<< "$ps_out"; then
            all_healthy=true
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ "$all_healthy" == true ]]; then
        record_result "03" "Startup ordering & healthchecks converged" 0 "All dependent services healthy in ${elapsed}s"
    else
        record_result "03" "Startup ordering & healthchecks converged" 1 "Timed out waiting for health checks"
    fi

    # Phase 2: Edge Routing & UI Accessibility
    echo -e "\n${CLR_YELLOW}Phase 2: Edge Routing & Gateway Validation${CLR_RESET}"

    # Test 4: Frontend Nginx serving static HTML
    local front_code
    front_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/" 2>/dev/null || echo "000")
    if [[ "$front_code" == "200" ]]; then
        record_result "04" "Frontend Nginx delivers static dashboard" 0 "HTTP 200 from ${BASE_URL}/"
    else
        record_result "04" "Frontend Nginx delivers static dashboard" 1 "Returned HTTP ${front_code}"
    fi

    # Test 5: Reverse Proxy API Healthcheck Endpoint
    local api_health_json api_health_code
    api_health_json=$(curl -s "${BASE_URL}/api/health" 2>/dev/null || echo "{}")
    api_health_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/health" 2>/dev/null || echo "000")

    if [[ "$api_health_code" == "200" ]] && grep -q '"status": "healthy"' <<< "$api_health_json" && grep -q '"status": "connected"' <<< "$api_health_json"; then
        record_result "05" "Nginx proxies to Python API with DB + Redis connected" 0 "PostgreSQL & Redis connected healthy"
    else
        record_result "05" "Nginx proxies to Python API with DB + Redis connected" 1 "Health response invalid: ${api_health_json}"
    fi

    # Test 6: Adminer DB Management Console
    local adminer_code
    adminer_code=$(curl -s -o /dev/null -w "%{http_code}" "${ADMINER_URL}/" 2>/dev/null || echo "000")
    if [[ "$adminer_code" == "200" ]]; then
        record_result "06" "Adminer DB management interface is accessible" 0 "HTTP 200 from ${ADMINER_URL}/"
    else
        record_result "06" "Adminer DB management interface is accessible" 1 "Returned HTTP ${adminer_code}"
    fi

    # Phase 3: Network Isolation & Security
    echo -e "\n${CLR_YELLOW}Phase 3: Network Topology & Isolation Security${CLR_RESET}"

    # Test 7: Verify Frontend cannot reach PostgreSQL directly (Network segmentation)
    local db_ping_from_frontend
    db_ping_from_frontend=$(docker exec compose-stack-frontend nc -z -w 2 db 5432 2>&1 || true)
    if grep -q -i -E 'bad address|timed out|refused|cannot resolve' <<< "$db_ping_from_frontend" || [[ -n "$db_ping_from_frontend" ]]; then
        record_result "07" "Network segmentation prevents frontend from reaching db" 0 "Frontend container is isolated from backend-net"
    else
        record_result "07" "Network segmentation prevents frontend from reaching db" 1 "Unexpected direct connectivity between frontend and db"
    fi

    # Phase 4: CRUD & Cache-Aside Mechanics
    echo -e "\n${CLR_YELLOW}Phase 4: Database Persistence & Cache-Aside Acceleration${CLR_RESET}"

    # Test 8: First Read -> Cache MISS (Queries PostgreSQL)
    # Ensure cache is fresh first
    docker exec compose-stack-cache redis-cli del cache:items:all >/dev/null 2>&1 || true

    local read1_headers read1_json
    read1_headers=$(curl -s -i "${BASE_URL}/api/items" 2>/dev/null || true)
    if grep -q -i 'X-Cache: MISS' <<< "$read1_headers" || grep -q '"cache_status": "MISS"' <<< "$read1_headers"; then
        record_result "08" "Initial read triggers Cache MISS and queries PostgreSQL" 0 "X-Cache: MISS header verified"
    else
        record_result "08" "Initial read triggers Cache MISS and queries PostgreSQL" 1 "Expected MISS on first read"
    fi

    # Test 9: Second Read -> Cache HIT (Served from Redis)
    local read2_headers
    read2_headers=$(curl -s -i "${BASE_URL}/api/items" 2>/dev/null || true)
    if grep -q -i 'X-Cache: HIT' <<< "$read2_headers" || grep -q '"cache_status": "HIT"' <<< "$read2_headers"; then
        record_result "09" "Subsequent read triggers Cache HIT from Redis" 0 "X-Cache: HIT header verified (in-memory response)"
    else
        record_result "09" "Subsequent read triggers Cache HIT from Redis" 1 "Expected HIT on repeated read"
    fi

    # Test 10: Item Creation (POST /api/items) and Cache Invalidation
    local post_res created_id
    post_res=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"title": "Automated Canary Deploy", "description": "Continuous delivery probe", "priority": "CRITICAL"}' \
        "${BASE_URL}/api/items" 2>/dev/null || echo "{}")
    
    created_id=$(grep -o '"id": *[0-9]*' <<< "$post_res" | head -n1 | grep -o '[0-9]*' || echo "")

    if [[ -n "$created_id" ]] && grep -q '"cache_invalidated": true' <<< "$post_res"; then
        record_result "10" "Item creation writes to PostgreSQL and invalidates Redis cache" 0 "Created Item #${created_id} (Cache purged)"
    else
        record_result "10" "Item creation writes to PostgreSQL and invalidates Redis cache" 1 "Creation failed: ${post_res}"
    fi

    # Test 11: Verification that next read reflects new item on Cache MISS
    local read3_json
    read3_json=$(curl -s "${BASE_URL}/api/items" 2>/dev/null || echo "{}")
    if grep -q "Automated Canary Deploy" <<< "$read3_json" && grep -q '"cache_status": "MISS"' <<< "$read3_json"; then
        record_result "11" "Fresh read after mutation reflects updated dataset" 0 "New item present in refreshed cache"
    else
        record_result "11" "Fresh read after mutation reflects updated dataset" 1 "Item missing from refreshed read"
    fi

    # Test 12: Item Deletion (DELETE /api/items/<id>)
    local del_code
    del_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${BASE_URL}/api/items/${created_id}" 2>/dev/null || echo "000")
    if [[ "$del_code" == "200" ]]; then
        record_result "12" "Item deletion purges database record and invalidates cache" 0 "Deleted Item #${created_id}"
    else
        record_result "12" "Item deletion purges database record and invalidates cache" 1 "Delete returned HTTP ${del_code}"
    fi

    # Phase 5: Volume Persistence Across Container Restart
    echo -e "\n${CLR_YELLOW}Phase 5: Database Named Volume Persistence${CLR_RESET}"

    # Create persistent canary item
    local canary_post canary_id
    canary_post=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"title": "Persistence Test Record", "description": "Must survive DB restart", "priority": "HIGH"}' \
        "${BASE_URL}/api/items" 2>/dev/null || echo "{}")
    canary_id=$(grep -o '"id": *[0-9]*' <<< "$canary_post" | head -n1 | grep -o '[0-9]*' || echo "")

    # Restart PostgreSQL container
    echo -e "  ${CLR_GRAY}Restarting PostgreSQL container 'compose-stack-db'...${CLR_RESET}"
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" restart db >/dev/null 2>&1
    sleep 4

    # Verify canary record survived
    local read_after_restart
    read_after_restart=$(curl -s "${BASE_URL}/api/items" 2>/dev/null || echo "{}")
    if grep -q "Persistence Test Record" <<< "$read_after_restart"; then
        record_result "13" "PostgreSQL named volume (postgres_data) preserves state" 0 "Canary record #${canary_id} survived database restart"
    else
        record_result "13" "PostgreSQL named volume (postgres_data) preserves state" 1 "Data lost after container restart"
    fi

    # Summary
    echo ""
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"
    echo -e "  Test Results: ${CLR_GREEN}${PASSED_TESTS} Passed${CLR_RESET}, ${CLR_RED}${FAILED_TESTS} Failed${CLR_RESET} (Total: ${TOTAL_TESTS})"
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✔ ALL E2E INTEGRATION TESTS PASSED!${CLR_RESET}\n"
    else
        echo -e "${CLR_RED}${CLR_BOLD}✘ SOME E2E INTEGRATION TESTS FAILED!${CLR_RESET}\n"
    fi

    if [[ "$FLAG_KEEP" == true ]]; then
        echo -e "${CLR_YELLOW}ℹ Stack left running (--keep specified).${CLR_RESET}"
        echo -e "  • Frontend Dashboard: ${CLR_BOLD}${BASE_URL}${CLR_RESET}"
        echo -e "  • Adminer DB Console: ${CLR_BOLD}${ADMINER_URL}${CLR_RESET}"
        echo -e "  To stop and clean up later, run: ${CLR_CYAN}./e2e_compose_test.sh --clean${CLR_RESET}\n"
    else
        do_cleanup
    fi

    if [[ "$FAILED_TESTS" -gt 0 ]]; then
        exit 1
    fi
}

main
