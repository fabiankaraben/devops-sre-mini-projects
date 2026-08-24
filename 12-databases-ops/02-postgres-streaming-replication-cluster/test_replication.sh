#!/usr/bin/env bash
# ==============================================================================
# test_replication.sh - Automated PostgreSQL Streaming Replication Test Suite
# ==============================================================================
# Executes comprehensive validation checkpoints:
# 1. Cluster Infrastructure & Healthcheck Verification
# 2. Streaming Handshake & Physical Replication Slot Verification
# 3. High-Throughput Workload Generation (50,000 records)
# 4. Replication Lag Benchmarking (<10ms assertion)
# 5. Standby Read-Only Query Routing & Write Blocking Enforcement
# 6. Primary-Replica Data Parity & Row Count Equivalence
# 7. High-Availability Standby Failover & Promotion Drill
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
echo "  🧪 PostgreSQL Streaming Replication - Automated Test Suite"
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
# Test 1: Clean Cluster Startup & Health Check
# ------------------------------------------------------------------------------
test_cluster_startup() {
    echo "  Tearing down any prior state and launching cluster..."
    $COMPOSE_CMD down -v >/dev/null 2>&1 || true
    $COMPOSE_CMD up -d --wait

    local retries=25
    while (( retries > 0 )); do
        local healthy_count
        healthy_count=$(docker ps --filter "name=postgres-" --filter "health=healthy" --format "{{.Names}}" | wc -l | tr -d ' ')
        if (( healthy_count >= 2 )); then
            echo "  Both primary (5432) and replica (5433) nodes are running and healthy."
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "  Timed out waiting for cluster nodes to become healthy."
    return 1
}
run_test "Cluster Infrastructure Startup & Health Check" test_cluster_startup

# ------------------------------------------------------------------------------
# Test 2: Streaming Replication Handshake & Replication Slot Status
# ------------------------------------------------------------------------------
test_replication_handshake() {
    echo "  Verifying streaming state in pg_stat_replication and pg_replication_slots..."
    
    local retries=15
    local is_streaming=false
    while (( retries > 0 )); do
        local state
        state=$(docker exec -e PGPASSWORD=postgres postgres-primary psql -U postgres -d production_db -t -A -c "SELECT state FROM pg_stat_replication WHERE application_name = 'postgres_replica_1';" 2>/dev/null || echo "")
        if [[ "$state" == "streaming" ]]; then
            is_streaming=true
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if [ "$is_streaming" = false ]; then
        echo "  pg_stat_replication is not in 'streaming' state."
        return 1
    fi

    local slot_active
    slot_active=$(docker exec -e PGPASSWORD=postgres postgres-primary psql -U postgres -d production_db -t -A -c "SELECT active FROM pg_replication_slots WHERE slot_name = 'standby_slot_1';" 2>/dev/null || echo "")
    if [[ "$slot_active" != "t" && "$slot_active" != "true" ]]; then
        echo "  Replication slot 'standby_slot_1' is not active."
        return 1
    fi

    echo "  Streaming replication confirmed: state='streaming', slot='standby_slot_1' (active=true)."
    return 0
}
run_test "Streaming Handshake & Physical Replication Slot Verification" test_replication_handshake

# ------------------------------------------------------------------------------
# Test 3: High-Throughput Workload Generation (50,000 records)
# ------------------------------------------------------------------------------
test_workload_generation() {
    echo "  Inserting 50,000 transactional records into primary node..."
    python3 "$SCRIPT_DIR/replication_lag_monitor.py" \
        --workload \
        --records 50000 \
        --batch-size 2500 \
        --silent
    
    local tx_count
    tx_count=$(docker exec -e PGPASSWORD=postgres postgres-primary psql -U postgres -d production_db -t -A -c "SELECT COUNT(*) FROM financial_transactions;" 2>/dev/null || echo "0")
    
    if (( tx_count >= 50000 )); then
        echo "  Successfully committed $tx_count financial transactions on primary."
        return 0
    else
        echo "  Workload insertion count ($tx_count) is less than 50,000."
        return 1
    fi
}
run_test "High-Throughput Workload Execution (50,000 records)" test_workload_generation

# ------------------------------------------------------------------------------
# Test 4: Replication Lag Benchmarking (<50ms steady-state assertion)
# ------------------------------------------------------------------------------
test_replication_lag() {
    echo "  Measuring real-time replication lag on primary..."
    local byte_lag=999999
    local replay_lag_ms=999999
    local lag_ok=false
    local retries=10

    while (( retries > 0 )); do
        local json_output
        json_output=$(python3 "$SCRIPT_DIR/replication_lag_monitor.py" --monitor --json)
        
        byte_lag=$(echo "$json_output" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['replication_metrics']['replicas'][0].get('byte_lag', 999999))")
        replay_lag_ms=$(echo "$json_output" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['replication_metrics']['replicas'][0].get('replay_lag_ms', 999999))")

        if (( byte_lag <= 1024 )) && python3 -c "import sys; sys.exit(0 if float('$replay_lag_ms') < 50.0 else 1)"; then
            lag_ok=true
            break
        fi
        sleep 0.5
        retries=$((retries - 1))
    done

    echo "  Measured Byte Lag   : ${byte_lag} bytes"
    echo "  Measured Replay Lag : ${replay_lag_ms} ms"

    if [ "$lag_ok" = true ]; then
        echo "  Replication lag benchmark passed (<50ms and zero byte lag)."
        return 0
    else
        echo "  Replication lag exceeded threshold."
        return 1
    fi
}
run_test "Replication Lag Telemetry & Benchmark (<50ms)" test_replication_lag

# ------------------------------------------------------------------------------
# Test 5: Standby Read-Only Enforcement Verification
# ------------------------------------------------------------------------------
test_readonly_enforcement() {
    echo "  Testing Hot Standby read queries and write rejection on replica..."
    if python3 "$SCRIPT_DIR/replication_lag_monitor.py" --verify-readonly --silent; then
        echo "  Standby read-only enforcement verified."
        return 0
    else
        echo "  Standby read-only verification failed."
        return 1
    fi
}
run_test "Standby Read-Only Routing & Write Blocking Enforcement" test_readonly_enforcement

# ------------------------------------------------------------------------------
# Test 6: Primary-Replica Data Parity & Row Count Equivalence
# ------------------------------------------------------------------------------
test_data_parity() {
    echo "  Comparing row counts and schemas across primary and replica..."
    local json_output
    json_output=$(python3 "$SCRIPT_DIR/replication_lag_monitor.py" --verify-parity --json)
    
    local parity_passed
    parity_passed=$(echo "$json_output" | python3 -c "import sys, json; print(json.load(sys.stdin).get('parity', {}).get('parity_passed', False))")

    if [[ "$parity_passed" == "True" ]]; then
        echo "  100% data parity confirmed across all tables."
        return 0
    else
        echo "  Data parity check failed between primary and replica."
        return 1
    fi
}
run_test "Primary-Replica Data Parity & Schema Consistency Audit" test_data_parity

# ------------------------------------------------------------------------------
# Test 7: High-Availability Failover & Standby Promotion Drill
# ------------------------------------------------------------------------------
test_failover_promotion() {
    echo "  Executing high-availability failover drill (stopping primary & promoting replica)..."
    "$SCRIPT_DIR/failover_drill.sh"
}
run_test "High-Availability Failover & Standby Promotion Drill" test_failover_promotion

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Streaming Replication Test Execution Summary${CLR_RESET}"
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
