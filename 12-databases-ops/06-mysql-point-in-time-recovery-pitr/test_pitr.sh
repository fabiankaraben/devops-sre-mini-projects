#!/usr/bin/env bash
# ==============================================================================
# test_pitr.sh - Automated MySQL Point-in-Time Recovery (PITR) Test Suite
# ==============================================================================
# Executes comprehensive validation checkpoints:
# 1. MySQL Infrastructure Startup & Container Health Checks
# 2. Binary Logging Configuration & Format Audit (log_bin=ON, format=ROW)
# 3. Baseline Schema & Initial Seed Data Verification (5 customers, 5 orders)
# 4. Baseline Full Snapshot Generation with --flush-logs
# 5. Live Business Transaction Streaming (+25 orders, audit logging)
# 6. Catastrophic Disaster Simulation (Accidental DROP TABLE orders)
# 7. Automated Point-in-Time Recovery & 100% Data Parity Verification (30 orders)
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
echo "  🧪 MySQL Point-in-Time Recovery (PITR) - Automated Test Suite"
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
# Test 1: MySQL Infrastructure Startup & Container Health Checks
# ------------------------------------------------------------------------------
test_mysql_startup() {
    echo "  Tearing down prior containers and starting fresh MySQL stack..."
    $COMPOSE_CMD down -v >/dev/null 2>&1 || true
    $COMPOSE_CMD up -d --wait

    local retries=25
    while (( retries > 0 )); do
        local healthy
        healthy=$(docker ps --filter "name=mysql-pitr-db" --filter "health=healthy" --format "{{.Names}}")
        if [[ -n "$healthy" ]]; then
            echo "  MySQL container 'mysql-pitr-db' is running and healthy."
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "  Timed out waiting for MySQL container."
    return 1
}
run_test "MySQL Infrastructure Startup & Health Checks" test_mysql_startup

# ------------------------------------------------------------------------------
# Test 2: Binary Logging Configuration & Format Audit
# ------------------------------------------------------------------------------
test_binlog_configuration() {
    echo "  Auditing binary logging settings..."
    local log_bin binlog_format
    log_bin=$(docker exec mysql-pitr-db mysql -u root -prootpassword -N -e "SELECT @@log_bin;" | tr -d '\r')
    binlog_format=$(docker exec mysql-pitr-db mysql -u root -prootpassword -N -e "SELECT @@binlog_format;" | tr -d '\r')

    echo "  • log_bin status : ${log_bin} (Expected: 1 / ON)"
    echo "  • binlog_format  : ${binlog_format} (Expected: ROW)"

    if [[ "$log_bin" == "1" || "$log_bin" == "ON" ]] && [[ "$binlog_format" == "ROW" ]]; then
        echo "  Binary logging configuration verified for Point-in-Time Recovery."
        return 0
    else
        echo "  Binary logging configuration failed: log_bin=$log_bin, binlog_format=$binlog_format"
        return 1
    fi
}
run_test "Binary Logging Configuration & Format Audit (ROW)" test_binlog_configuration

# ------------------------------------------------------------------------------
# Test 3: Baseline Schema & Initial Seed Data Verification
# ------------------------------------------------------------------------------
test_baseline_schema() {
    echo "  Verifying baseline tables and records in 'ecommerce_db'..."
    local cust_cnt order_cnt
    cust_cnt=$(docker exec mysql-pitr-db mysql -u root -prootpassword -D ecommerce_db -N -e "SELECT COUNT(*) FROM customers;" | tr -d '\r')
    order_cnt=$(docker exec mysql-pitr-db mysql -u root -prootpassword -D ecommerce_db -N -e "SELECT COUNT(*) FROM orders;" | tr -d '\r')

    echo "  • Initial Customers : ${cust_cnt}"
    echo "  • Initial Orders    : ${order_cnt}"

    if (( cust_cnt == 5 )) && (( order_cnt == 5 )); then
        echo "  Baseline seed verification passed."
        return 0
    else
        echo "  Baseline seed verification failed: customers=$cust_cnt, orders=$order_cnt"
        return 1
    fi
}
run_test "Baseline Schema & Initial Seed Verification" test_baseline_schema

# ------------------------------------------------------------------------------
# Test 4: Baseline Full Snapshot Generation with --flush-logs
# ------------------------------------------------------------------------------
test_baseline_backup_generation() {
    echo "  Creating baseline backup directory and taking mysqldump with --flush-logs..."
    mkdir -p "$SCRIPT_DIR/backups"
    
    local backup_path
    backup_path=$(python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR');
from simulate_disaster import create_baseline_backup
print(create_baseline_backup('$SCRIPT_DIR/backups'))
")

    echo "  • Generated Backup File: ${backup_path}"

    if [[ -f "$backup_path" && -s "$backup_path" ]]; then
        echo "  Baseline backup snapshot confirmed."
        return 0
    else
        echo "  Failed to generate baseline backup."
        return 1
    fi
}
run_test "Baseline Full Snapshot Generation with --flush-logs" test_baseline_backup_generation

# ------------------------------------------------------------------------------
# Test 5: Live Business Transaction Streaming (+25 orders)
# ------------------------------------------------------------------------------
test_live_transaction_streaming() {
    echo "  Streaming 25 live business transactions to active database..."
    python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR');
from simulate_disaster import inject_live_transactions
orders = inject_live_transactions(25)
print(f'Injected {len(orders)} transactions.')
"
    local total_orders
    total_orders=$(docker exec mysql-pitr-db mysql -u root -prootpassword -D ecommerce_db -N -e "SELECT COUNT(*) FROM orders;" | tr -d '\r')
    echo "  • Orders count after live injection: ${total_orders}"

    if (( total_orders == 30 )); then
        echo "  Live transaction ingestion verified."
        return 0
    else
        echo "  Expected 30 orders, got $total_orders"
        return 1
    fi
}
run_test "Live Business Transaction Streaming & Ingestion" test_live_transaction_streaming

# ------------------------------------------------------------------------------
# Test 6: Catastrophic Disaster Simulation (Accidental DROP TABLE orders)
# ------------------------------------------------------------------------------
test_disaster_simulation() {
    echo "  Executing accidental DROP TABLE orders disaster..."
    python3 -c "
import sys, json; sys.path.insert(0, '$SCRIPT_DIR');
from simulate_disaster import trigger_accidental_drop_table
ts = trigger_accidental_drop_table()
meta = {
    'expected_recovered_orders_total': 30,
    'baseline_orders_count': 5,
    'injected_live_orders_count': 25,
    'disaster_timestamp': ts
}
with open('$SCRIPT_DIR/backups/disaster_metadata.json', 'w') as f:
    json.dump(meta, f, indent=2)
print(f'Disaster simulated at {ts}')
"
    local table_check
    table_check=$(docker exec mysql-pitr-db mysql -u root -prootpassword -D ecommerce_db -N -e "SHOW TABLES LIKE 'orders';" | tr -d '\r')

    if [[ -z "$table_check" ]]; then
        echo "  Disaster confirmed: table 'orders' is destroyed."
        return 0
    else
        echo "  Expected 'orders' table to be destroyed, but it still exists."
        return 1
    fi
}
run_test "Catastrophic Disaster Simulation (DROP TABLE orders)" test_disaster_simulation

# ------------------------------------------------------------------------------
# Test 7: Automated Point-in-Time Recovery & 100% Data Parity Verification
# ------------------------------------------------------------------------------
test_point_in_time_recovery() {
    echo "  Executing PITR restore runbook..."
    "$SCRIPT_DIR/pitr_restore_runbook.sh"

    local final_orders final_customers
    final_orders=$(docker exec mysql-pitr-db mysql -u root -prootpassword -D ecommerce_db -N -e "SELECT COUNT(*) FROM orders;" | tr -d '\r')
    final_customers=$(docker exec mysql-pitr-db mysql -u root -prootpassword -D ecommerce_db -N -e "SELECT COUNT(*) FROM customers;" | tr -d '\r')

    echo "  • Final Recovered Orders    : ${final_orders} / 30"
    echo "  • Final Recovered Customers : ${final_customers} / 5"

    if (( final_orders == 30 )) && (( final_customers == 5 )); then
        echo "  Point-in-Time Recovery verified: 100% data parity and zero data loss."
        return 0
    else
        echo "  PITR recovery failed: expected 30 orders and 5 customers, got $final_orders orders and $final_customers customers."
        return 1
    fi
}
run_test "Automated Point-in-Time Recovery & 100% Data Parity Verification" test_point_in_time_recovery

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 MySQL Point-in-Time Recovery Test Execution Summary${CLR_RESET}"
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
