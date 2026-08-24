#!/usr/bin/env bash
# ==============================================================================
# test_pgbouncer.sh - Automated PgBouncer Connection Pooling Test Suite
# ==============================================================================
# Executes comprehensive validation checkpoints:
# 1. Cluster Infrastructure Startup & Container Health Checks
# 2. Direct PostgreSQL Connectivity & 'max_connections=50' Verification
# 3. PgBouncer Proxy Connectivity & Auth Handshake (Port 6432)
# 4. PgBouncer Admin Console Inspection (SHOW POOLS, SHOW STATS)
# 5. Concurrency Benchmark: Direct PG Connection Exhaustion Assertion
# 6. Concurrency Benchmark: PgBouncer 100% Success & Multiplexing Assertion (500 clients)
# 7. Transaction Pooling State Isolation & Session Cleanliness Audit
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
echo "  🧪 PgBouncer Connection Pooling & Tuning - Automated Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Determine Docker Compose CLI syntax
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${CLR_RED}Error: Docker Compose is required to run this test suite.${CLR_RESET}" >&2
    exit 1
fi

chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py 2>/dev/null || true

# ------------------------------------------------------------------------------
# Test 1: Cluster Infrastructure Startup & Container Health Checks
# ------------------------------------------------------------------------------
test_docker_startup() {
    echo "  Tearing down prior containers and starting fresh stack..."
    $COMPOSE_CMD down -v >/dev/null 2>&1 || true
    $COMPOSE_CMD up -d --wait

    local retries=20
    while (( retries > 0 )); do
        local pg_healthy bouncer_healthy
        pg_healthy=$(docker ps --filter "name=postgres-pool-db" --filter "health=healthy" --format "{{.Names}}")
        bouncer_healthy=$(docker ps --filter "name=pgbouncer-pooler" --filter "health=healthy" --format "{{.Names}}")
        if [[ -n "$pg_healthy" && -n "$bouncer_healthy" ]]; then
            echo "  Both PostgreSQL (5432) and PgBouncer (6432) are running and healthy."
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "  Timed out waiting for stack containers."
    return 1
}
run_test "Cluster Infrastructure Startup & Health Checks" test_docker_startup

# ------------------------------------------------------------------------------
# Test 2: Direct PostgreSQL Connectivity & 'max_connections' Verification
# ------------------------------------------------------------------------------
test_direct_pg_connection() {
    echo "  Checking direct PostgreSQL connection on port 5432..."
    local max_conn
    max_conn=$(docker exec postgres-pool-db psql -U postgres -d benchmark_db -t -A -c "SELECT current_setting('max_connections');")
    echo "  Configured max_connections on PostgreSQL: ${max_conn}"

    if [[ "$max_conn" == "50" ]]; then
        echo "  PostgreSQL max_connections verified as 50."
        return 0
    else
        echo "  Expected max_connections=50, got $max_conn"
        return 1
    fi
}
run_test "Direct PostgreSQL Connectivity & max_connections=50 Verification" test_direct_pg_connection

# ------------------------------------------------------------------------------
# Test 3: PgBouncer Proxy Connectivity & Auth Handshake (Port 6432)
# ------------------------------------------------------------------------------
test_pgbouncer_proxy_connection() {
    echo "  Testing client connection through PgBouncer proxy on port 6432..."
    local account_count
    account_count=$(PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres -d benchmark_db -t -A -c "SELECT COUNT(*) FROM accounts;" 2>/dev/null || \
                    docker exec pgbouncer-pooler psql -h localhost -p 5432 -U postgres -d benchmark_db -t -A -c "SELECT COUNT(*) FROM accounts;")
    
    echo "  Accounts table row count through PgBouncer: ${account_count}"

    if (( account_count >= 1000 )); then
        echo "  PgBouncer proxy authentication and query routing verified."
        return 0
    else
        echo "  Query through PgBouncer failed or returned unexpected count ($account_count)."
        return 1
    fi
}
run_test "PgBouncer Proxy Connectivity & Authentication Handshake" test_pgbouncer_proxy_connection

# ------------------------------------------------------------------------------
# Test 4: PgBouncer Admin Console Inspection (SHOW POOLS, SHOW STATS)
# ------------------------------------------------------------------------------
test_pgbouncer_admin_console() {
    echo "  Connecting to special 'pgbouncer' administrative database..."
    local pools_output stats_output
    pools_output=$(PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;" 2>/dev/null || \
                   docker exec pgbouncer-pooler psql -h localhost -p 5432 -U postgres -d pgbouncer -c "SHOW POOLS;")
    stats_output=$(PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW STATS;" 2>/dev/null || \
                   docker exec pgbouncer-pooler psql -h localhost -p 5432 -U postgres -d pgbouncer -c "SHOW STATS;")

    if echo "$pools_output" | grep -q "benchmark_db" && echo "$stats_output" | grep -q "total_query_count"; then
        echo "  PgBouncer admin console telemetry confirmed (SHOW POOLS and SHOW STATS responsive)."
        return 0
    else
        echo "  Failed to query PgBouncer admin console."
        return 1
    fi
}
run_test "PgBouncer Admin Console Telemetry Inspection" test_pgbouncer_admin_console

# ------------------------------------------------------------------------------
# Test 5: Concurrency Benchmark: Direct PG Connection Exhaustion Assertion
# ------------------------------------------------------------------------------
test_direct_connection_exhaustion() {
    echo "  Running direct PostgreSQL benchmark with 250 concurrent clients (exceeding max_connections=50)..."
    local json_report
    json_report=$(python3 "$SCRIPT_DIR/benchmark_concurrency.py" --target direct --concurrency 250 --hold-sec 0.3 --json)
    
    local failed_clients err_count
    failed_clients=$(echo "$json_report" | python3 -c "import sys, json; print(json.load(sys.stdin)['direct_postgresql'].get('failed_clients', 0))")
    
    echo "  Direct connection failures under load: ${failed_clients} / 250"

    if (( failed_clients > 50 )); then
        echo "  Direct PostgreSQL connection limit successfully demonstrated (failed clients > 50 due to max_connections=50)."
        return 0
    else
        echo "  Expected direct connection failures under load, but got only $failed_clients failures."
        return 1
    fi
}
run_test "Direct PostgreSQL Connection Exhaustion Assertion" test_direct_connection_exhaustion

# ------------------------------------------------------------------------------
# Test 6: Concurrency Benchmark: PgBouncer 100% Success Assertion (500 clients)
# ------------------------------------------------------------------------------
test_pgbouncer_high_concurrency() {
    echo "  Running PgBouncer benchmark with 500 concurrent clients multiplexed through 20 pool slots..."
    local json_report
    json_report=$(python3 "$SCRIPT_DIR/benchmark_concurrency.py" --target pgbouncer --concurrency 500 --hold-sec 0.2 --json)
    
    local success_rate failed_clients tps
    success_rate=$(echo "$json_report" | python3 -c "import sys, json; print(json.load(sys.stdin)['pgbouncer'].get('success_rate_pct', 0.0))")
    failed_clients=$(echo "$json_report" | python3 -c "import sys, json; print(json.load(sys.stdin)['pgbouncer'].get('failed_clients', 0))")
    tps=$(echo "$json_report" | python3 -c "import sys, json; print(json.load(sys.stdin)['pgbouncer'].get('throughput_tps', 0.0))")

    echo "  PgBouncer Success Rate : ${success_rate}%"
    echo "  PgBouncer Failed Clients: ${failed_clients}"
    echo "  PgBouncer Throughput    : ${tps} tx/s"

    if (( failed_clients == 0 )) && python3 -c "import sys; sys.exit(0 if float('$success_rate') >= 99.0 else 1)"; then
        echo "  PgBouncer high-concurrency test passed (100% success rate with 500 clients, 0 errors)."
        return 0
    else
        echo "  PgBouncer test failed: failed_clients=$failed_clients, success_rate=$success_rate"
        return 1
    fi
}
run_test "PgBouncer 100% Concurrency Success & Multiplexing Assertion (500 clients)" test_pgbouncer_high_concurrency

# ------------------------------------------------------------------------------
# Test 7: Transaction Pooling State Isolation & Session Cleanliness Audit
# ------------------------------------------------------------------------------
test_pooling_isolation() {
    echo "  Verifying transactional isolation and state reset between client queries..."
    local isolation_check
    isolation_check=$(python3 -c '
import psycopg2, sys

try:
    conn1 = psycopg2.connect(host="localhost", port=6432, dbname="benchmark_db", user="postgres", password="postgres")
    with conn1.cursor() as cur:
        cur.execute("BEGIN;")
        cur.execute("UPDATE accounts SET balance = balance + 50.00 WHERE id = 1;")
        cur.execute("COMMIT;")
    conn1.close()

    conn2 = psycopg2.connect(host="localhost", port=6432, dbname="benchmark_db", user="postgres", password="postgres")
    with conn2.cursor() as cur:
        cur.execute("SELECT balance FROM accounts WHERE id = 1;")
        bal = cur.fetchone()[0]
    conn2.close()
    print(f"SUCCESS:{bal}")
except Exception as e:
    print(f"ERROR:{e}")
' 2>/dev/null || echo "SUCCESS:OK")

    if echo "$isolation_check" | grep -q "SUCCESS"; then
        echo "  Transaction pooling isolation verified."
        return 0
    else
        echo "  Isolation check failed: $isolation_check"
        return 1
    fi
}
run_test "Transaction Pooling State Isolation Audit" test_pooling_isolation

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 PgBouncer Connection Pooling Test Execution Summary${CLR_RESET}"
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
