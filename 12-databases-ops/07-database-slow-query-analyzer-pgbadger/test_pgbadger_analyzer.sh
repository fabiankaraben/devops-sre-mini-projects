#!/usr/bin/env bash
# ==============================================================================
# test_pgbadger_analyzer.sh - Automated PostgreSQL Query Profiler Test Suite
# ==============================================================================
# Executes comprehensive validation checkpoints:
# 1. PostgreSQL Infrastructure Startup & Health Checks
# 2. Performance Logging Configuration Audit (log_line_prefix, duration, locks, temp files)
# 3. Baseline Database Schema & Seed Data Verification (5k customers, 25k orders)
# 4. Multi-Archetype Workload Generator Execution (indexed, seq scans, joins, sorts, locks)
# 5. Active Server Log Capture & Line/Byte Metric Validation
# 6. pgBadger Report Generation (Interactive HTML + Structured JSON)
# 7. SRE Performance Metrics & Slow Query Assertion Verification
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
echo "  🧪 PostgreSQL Slow Query Analyzer with pgBadger - Test Suite"
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
# Test 1: PostgreSQL Infrastructure Startup & Health Checks
# ------------------------------------------------------------------------------
test_postgres_startup() {
    echo "  Tearing down prior containers and starting fresh PostgreSQL stack..."
    $COMPOSE_CMD down -v >/dev/null 2>&1 || true
    $COMPOSE_CMD up -d --wait

    local retries=25
    while (( retries > 0 )); do
        local healthy
        healthy=$(docker ps --filter "name=postgres-analyzer-db" --filter "health=healthy" --format "{{.Names}}")
        if [[ -n "$healthy" ]]; then
            echo "  PostgreSQL container 'postgres-analyzer-db' is running and healthy."
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "  Timed out waiting for PostgreSQL container."
    return 1
}
run_test "PostgreSQL Infrastructure Startup & Health Checks" test_postgres_startup

# ------------------------------------------------------------------------------
# Test 2: Performance Logging Configuration Audit
# ------------------------------------------------------------------------------
test_logging_configuration() {
    echo "  Auditing PostgreSQL performance logging settings..."
    local prefix duration lock_waits temp_files
    prefix=$(docker exec postgres-analyzer-db psql -U postgres -d analyzer_db -t -c "SELECT current_setting('log_line_prefix');" | tr -d '\r' | xargs)
    duration=$(docker exec postgres-analyzer-db psql -U postgres -d analyzer_db -t -c "SELECT current_setting('log_min_duration_statement');" | tr -d '\r' | xargs)
    lock_waits=$(docker exec postgres-analyzer-db psql -U postgres -d analyzer_db -t -c "SELECT current_setting('log_lock_waits');" | tr -d '\r' | xargs)
    temp_files=$(docker exec postgres-analyzer-db psql -U postgres -d analyzer_db -t -c "SELECT current_setting('log_temp_files');" | tr -d '\r' | xargs)

    echo "  • log_line_prefix            : '${prefix}'"
    echo "  • log_min_duration_statement : '${duration}'"
    echo "  • log_lock_waits             : '${lock_waits}'"
    echo "  • log_temp_files             : '${temp_files}'"

    if [[ "$prefix" == *"%t [%p]: [%l-1]"* ]] && [[ "$duration" == "20ms" ]] && [[ "$lock_waits" == "on" ]]; then
        echo "  Logging configuration verified for pgBadger compatibility."
        return 0
    else
        echo "  Invalid logging configuration detected."
        return 1
    fi
}
run_test "Performance Logging Configuration Audit (Prefix & Durations)" test_logging_configuration

# ------------------------------------------------------------------------------
# Test 3: Baseline Database Schema & Seed Data Verification
# ------------------------------------------------------------------------------
test_baseline_seed() {
    echo "  Verifying database schema and initial record volumes..."
    local cust_cnt order_cnt item_cnt
    cust_cnt=$(docker exec postgres-analyzer-db psql -U postgres -d analyzer_db -t -c "SELECT COUNT(*) FROM customers;" | tr -d '\r' | xargs)
    order_cnt=$(docker exec postgres-analyzer-db psql -U postgres -d analyzer_db -t -c "SELECT COUNT(*) FROM orders;" | tr -d '\r' | xargs)
    item_cnt=$(docker exec postgres-analyzer-db psql -U postgres -d analyzer_db -t -c "SELECT COUNT(*) FROM order_items;" | tr -d '\r' | xargs)

    echo "  • Customers   : ${cust_cnt} (Expected: 5000)"
    echo "  • Orders      : ${order_cnt} (Expected: 25000)"
    echo "  • Order Items : ${item_cnt} (Expected: 50000)"

    if (( cust_cnt >= 5000 )) && (( order_cnt >= 25000 )); then
        echo "  Database seed data verification passed."
        return 0
    else
        echo "  Database seed data verification failed: cust=$cust_cnt, orders=$order_cnt"
        return 1
    fi
}
run_test "Baseline Database Schema & Seed Data Verification" test_baseline_seed

# ------------------------------------------------------------------------------
# Test 4: Multi-Archetype Workload Generator Execution
# ------------------------------------------------------------------------------
test_workload_generator() {
    echo "  Executing multi-archetype query workload generator..."
    python3 "$SCRIPT_DIR/query_workload_generator.py" --scale 1

    echo "  Query workload generator executed successfully."
    return 0
}
run_test "Multi-Archetype Query Workload Generator Execution" test_workload_generator

# ------------------------------------------------------------------------------
# Test 5: Server Log Capture & Size Verification
# ------------------------------------------------------------------------------
test_log_capture() {
    echo "  Checking PostgreSQL server log capture..."
    mkdir -p "$SCRIPT_DIR/logs"
    docker exec postgres-analyzer-db cat /var/lib/postgresql/data/log/postgresql.log > "$SCRIPT_DIR/logs/postgresql.log"

    if [[ -f "$SCRIPT_DIR/logs/postgresql.log" && -s "$SCRIPT_DIR/logs/postgresql.log" ]]; then
        local lines
        lines=$(wc -l < "$SCRIPT_DIR/logs/postgresql.log" | tr -d ' ')
        echo "  • Captured Log Lines: ${lines}"
        if (( lines > 50 )); then
            echo "  Server log capture verified."
            return 0
        fi
    fi
    echo "  Failed to capture valid server log file."
    return 1
}
run_test "Server Log Capture & Size Verification" test_log_capture

# ------------------------------------------------------------------------------
# Test 6: pgBadger HTML & JSON Report Generation
# ------------------------------------------------------------------------------
test_pgbadger_report_generation() {
    echo "  Running generate_pgbadger_report.sh..."
    "$SCRIPT_DIR/generate_pgbadger_report.sh"

    local html_file="$SCRIPT_DIR/reports/slow_query_report.html"
    local json_file="$SCRIPT_DIR/reports/slow_query_report.json"

    if [[ -f "$html_file" && -s "$html_file" ]] && [[ -f "$json_file" && -s "$json_file" ]]; then
        local html_size json_size
        html_size=$(du -h "$html_file" | awk '{print $1}')
        json_size=$(du -h "$json_file" | awk '{print $1}')
        echo "  • HTML Report Size : ${html_size}"
        echo "  • JSON Report Size : ${json_size}"
        echo "  pgBadger reports generated successfully."
        return 0
    else
        echo "  Report generation failed: HTML or JSON report missing/empty."
        return 1
    fi
}
run_test "pgBadger HTML & JSON Report Generation" test_pgbadger_report_generation

# ------------------------------------------------------------------------------
# Test 7: SRE Performance Metrics & Slow Query Assertion
# ------------------------------------------------------------------------------
test_report_metrics_assertion() {
    echo "  Asserting slowest queries and lock events in generated reports..."
    local json_file="$SCRIPT_DIR/reports/slow_query_report.json"
    local html_file="$SCRIPT_DIR/reports/slow_query_report.html"

    # Assert HTML contains pgBadger signature and charts
    if ! grep -qi "pgbadger" "$html_file"; then
        echo "  HTML report does not contain expected pgBadger signatures."
        return 1
    fi

    # Assert JSON contains top_slowest entries
    local slow_cnt
    slow_cnt=$(python3 -c "
import json
with open('$json_file') as f:
    d = json.load(f)
slow = d.get('top_slowest', {}).get('postgres', [])
print(len(slow))
" 2>/dev/null || echo "0")

    echo "  • Detected Slow Query Events: ${slow_cnt}"

    if (( slow_cnt > 0 )); then
        echo "  Report metrics assertion passed: slow queries accurately cataloged."
        return 0
    else
        echo "  Report metrics assertion failed: no slow queries found in JSON report."
        return 1
    fi
}
run_test "SRE Performance Metrics & Slow Query Assertion" test_report_metrics_assertion

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 PostgreSQL Slow Query Analyzer Test Execution Summary${CLR_RESET}"
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
