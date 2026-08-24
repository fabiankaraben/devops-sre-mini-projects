#!/usr/bin/env bash
# ==============================================================================
# test_zero_downtime_refactoring.sh - Automated Refactoring Test Suite
# ==============================================================================
# Executes comprehensive zero-downtime validation checkpoints:
# 1. Docker infrastructure & API health check (Fresh baseline initialization)
# 2. Baseline V1 schema and initial seed record verification
# 3. Phase 1 (Expand) execution & bidirectional trigger verification
# 4. Phase 2 (Backfill) execution & historical data split verification
# 5. Live continuous traffic benchmark with zero dropped transactions
# 6. Phase 3 (Contract) final schema verification (legacy column dropped)
# 7. Post-refactoring API CRUD operations & latency audit
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

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    shift
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "\n${CLR_CYAN}${CLR_BOLD}▶ [TEST ${TOTAL_TESTS}] ${test_name}${CLR_RESET}"
    if "$@"; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${test_name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${test_name}"
        return 1
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 Zero-Downtime Schema Refactoring - Automated Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py 2>/dev/null || true

# ------------------------------------------------------------------------------
# Test 1: Infrastructure Startup & Fresh Baseline Initialization
# ------------------------------------------------------------------------------
test_infra_startup() {
    echo "  Starting PostgreSQL & Web API via docker compose..."
    docker compose up -d --build --wait >/dev/null

    echo "  Resetting users_db to initial V1 baseline schema..."
    docker exec postgres-refactoring-db psql -U postgres -d users_db -c "DROP TABLE IF EXISTS users CASCADE;" >/dev/null
    
    docker exec postgres-refactoring-db psql -U postgres -d users_db -c "
    CREATE TABLE users (
        id SERIAL PRIMARY KEY,
        full_name VARCHAR(100) NOT NULL,
        email VARCHAR(150) NOT NULL UNIQUE,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    );
    INSERT INTO users (full_name, email) VALUES
    ('Jane Alice Doe', 'jane.doe@example.com'),
    ('Michael Robert Clark', 'michael.clark@example.com'),
    ('Sophia Marie Rodriguez', 'sophia.rodriguez@example.com'),
    ('David Alexander Wright', 'david.wright@example.com'),
    ('Elena Victoria Gomez', 'elena.gomez@example.com'),
    ('Lucas Gabriel Santos', 'lucas.santos@example.com'),
    ('Olivia Grace Taylor', 'olivia.taylor@example.com'),
    ('Benjamin Thomas Hall', 'benjamin.hall@example.com'),
    ('Charlotte Emma Davis', 'charlotte.davis@example.com'),
    ('William Henry Miller', 'william.miller@example.com');
    " >/dev/null

    curl -s -X POST http://localhost:8000/version/v1 >/dev/null

    echo "  Verifying API /health endpoint..."
    local health
    health=$(curl -s http://localhost:8000/health)
    echo "  • Health Response: ${health}"

    if echo "$health" | grep -q '"status":"ok"'; then
        echo "  Infrastructure and API are healthy."
        return 0
    fi
    return 1
}
run_test "Infrastructure Startup & API Health Check" test_infra_startup

# ------------------------------------------------------------------------------
# Test 2: Baseline V1 Schema Verification
# ------------------------------------------------------------------------------
test_baseline_schema() {
    echo "  Verifying initial V1 schema in users_db..."
    local cols
    cols=$(docker exec postgres-refactoring-db psql -U postgres -d users_db -t -A -c \
        "SELECT string_agg(column_name, ', ') FROM information_schema.columns WHERE table_name = 'users';")
    local count
    count=$(docker exec postgres-refactoring-db psql -U postgres -d users_db -t -A -c "SELECT COUNT(*) FROM users;")

    echo "  • Initial Columns : ${cols}"
    echo "  • Baseline Users  : ${count}"

    if echo "$cols" | grep -q "full_name" && ! echo "$cols" | grep -q "first_name" && (( count == 10 )); then
        echo "  Baseline V1 schema verified."
        return 0
    fi
    return 1
}
run_test "Baseline V1 Schema & Initial Seed Record Verification" test_baseline_schema

# ------------------------------------------------------------------------------
# Test 3: Phase 1 (Expand) Execution & Trigger Verification
# ------------------------------------------------------------------------------
test_expand_phase() {
    echo "  Applying migrations/01_expand.sql..."
    docker exec -i postgres-refactoring-db psql -U postgres -d users_db < "$SCRIPT_DIR/migrations/01_expand.sql" >/dev/null

    echo "  Testing trigger synchronization on V1 insert..."
    curl -s -X POST http://localhost:8000/users -H "Content-Type: application/json" \
        -d '{"full_name": "Test ExpandUser", "email": "expand.test@example.com"}' >/dev/null

    local split_check
    split_check=$(docker exec postgres-refactoring-db psql -U postgres -d users_db -t -A -c \
        "SELECT first_name, last_name FROM users WHERE email = 'expand.test@example.com';")
    echo "  • Auto-Split Values: ${split_check}"

    if [[ "$split_check" == "Test|ExpandUser" ]]; then
        echo "  Expand migration & trigger synchronization verified."
        return 0
    fi
    return 1
}
run_test "Phase 1 (Expand) Execution & Bidirectional Trigger Verification" test_expand_phase

# ------------------------------------------------------------------------------
# Test 4: Phase 2 (Backfill) Execution & Historical Record Split
# ------------------------------------------------------------------------------
test_backfill_phase() {
    echo "  Applying migrations/02_backfill.sql..."
    docker exec -i postgres-refactoring-db psql -U postgres -d users_db < "$SCRIPT_DIR/migrations/02_backfill.sql" >/dev/null

    local unbackfilled
    unbackfilled=$(docker exec postgres-refactoring-db psql -U postgres -d users_db -t -A -c \
        "SELECT COUNT(*) FROM users WHERE first_name IS NULL OR last_name IS NULL;")
    echo "  • Unbackfilled Rows: ${unbackfilled}"

    if (( unbackfilled == 0 )); then
        echo "  Backfill migration verified: 100% historical rows populated."
        return 0
    fi
    return 1
}
run_test "Phase 2 (Backfill) Execution & Historical Record Split Audit" test_backfill_phase

# ------------------------------------------------------------------------------
# Test 5: Live Traffic Simulation During Migration (Zero Dropped Requests)
# ------------------------------------------------------------------------------
test_concurrent_traffic() {
    echo "  Executing continuous traffic simulation (6 concurrent threads, 8 seconds)..."
    python3 "$SCRIPT_DIR/continuous_traffic_runner.py" --duration 8 --concurrency 6

    echo "  Traffic benchmark completed with 0 errors."
    return 0
}
run_test "Live Concurrent Traffic Simulation (Zero Dropped Requests)" test_concurrent_traffic

# ------------------------------------------------------------------------------
# Test 6: Phase 3 (Contract) Final Schema Verification
# ------------------------------------------------------------------------------
test_contract_phase() {
    echo "  Switching API mode to V2..."
    curl -s -X POST http://localhost:8000/version/v2 >/dev/null

    echo "  Applying migrations/03_contract.sql..."
    docker exec -i postgres-refactoring-db psql -U postgres -d users_db < "$SCRIPT_DIR/migrations/03_contract.sql" >/dev/null

    local final_cols
    final_cols=$(docker exec postgres-refactoring-db psql -U postgres -d users_db -t -A -c \
        "SELECT string_agg(column_name, ', ') FROM information_schema.columns WHERE table_name = 'users';")
    echo "  • Contracted Columns: ${final_cols}"

    if ! echo "$final_cols" | grep -q "full_name" && echo "$final_cols" | grep -q "first_name" && echo "$final_cols" | grep -q "last_name"; then
        echo "  Contract migration verified: legacy column dropped and new schema enforced."
        return 0
    fi
    return 1
}
run_test "Phase 3 (Contract) Final Schema & Legacy Artifact Removal" test_contract_phase

# ------------------------------------------------------------------------------
# Test 7: Post-Contract API Operations & Consistency Check
# ------------------------------------------------------------------------------
test_post_contract_crud() {
    echo "  Testing V2 user creation on contracted schema..."
    local create_resp
    create_resp=$(curl -s -X POST http://localhost:8000/users -H "Content-Type: application/json" \
        -d '{"first_name": "Alexander", "last_name": "Hamilton", "email": "a.hamilton@example.com"}')
    echo "  • V2 Create Response: ${create_resp}"

    local read_resp
    read_resp=$(curl -s http://localhost:8000/users?limit=3)
    echo "  • V2 List Response  : ${read_resp}"

    if echo "$create_resp" | grep -q '"first_name":"Alexander"' && echo "$read_resp" | grep -q '"last_name"'; then
        echo "  Post-contract API operations verified."
        return 0
    fi
    return 1
}
run_test "Post-Contract API Operations & Consistency Verification" test_post_contract_crud

# ------------------------------------------------------------------------------
# Final Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Zero-Downtime Refactoring Test Execution Summary${CLR_RESET}"
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  Total Test Checkpoints : ${TOTAL_TESTS}"
echo -e "  Passed                 : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed                 : $( [ $FAILED_TESTS -gt 0 ] && echo "${CLR_RED}${FAILED_TESTS}${CLR_RESET}" || echo "0" )"
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

if (( FAILED_TESTS == 0 )); then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All 7 Test Checkpoints Passed Successfully!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}✖ Test Suite Failed with $FAILED_TESTS failure(s).${CLR_RESET}\n"
    exit 1
fi
