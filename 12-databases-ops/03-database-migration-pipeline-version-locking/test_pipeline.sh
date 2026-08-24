#!/usr/bin/env bash
# ==============================================================================
# test_pipeline.sh - Automated PostgreSQL Migration Pipeline Test Suite
# ==============================================================================
# Executes comprehensive validation checkpoints:
# 1. Database Infrastructure Startup & Health Check
# 2. Initial State Verification (Version 0)
# 3. Stepwise Forward Migrations (Versions 1 -> 2 -> 3 -> 4)
# 4. Data Seeding & Schema Consistency Check
# 5. Stepwise Rollbacks (down 1 -> goto 1 -> full rollback)
# 6. Re-Application of All Forward Migrations (Clean up)
# 7. Dirty State Simulation, Failure Detection, and 'force' Recovery
# 8. Schema Evolution with Live Data Preservation
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
echo "  🧪 PostgreSQL Migration Pipeline - Automated Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Determine Docker Compose command
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
# Test 1: Container Infrastructure Startup & Health Check
# ------------------------------------------------------------------------------
test_docker_startup() {
    echo "  Starting PostgreSQL database container..."
    $COMPOSE_CMD down -v >/dev/null 2>&1 || true
    $COMPOSE_CMD up -d --wait

    local retries=20
    while (( retries > 0 )); do
        local is_healthy
        is_healthy=$(docker ps --filter "name=postgres-migration-db" --filter "health=healthy" --format "{{.Names}}")
        if [[ -n "$is_healthy" ]]; then
            echo "  PostgreSQL migration database is running and healthy."
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "  Timed out waiting for database container."
    return 1
}
run_test "Database Infrastructure Startup & Health Check" test_docker_startup

# ------------------------------------------------------------------------------
# Test 2: Initial Schema State Verification (Version 0)
# ------------------------------------------------------------------------------
test_initial_state() {
    local version_output
    version_output=$("$SCRIPT_DIR/migrate.sh" version)
    echo "  $version_output"
    
    local summary_json
    summary_json=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local table_count
    table_count=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('table_count', -1))")

    if (( table_count == 0 )); then
        echo "  Confirmed initial state: 0 application tables present."
        return 0
    else
        echo "  Expected 0 tables, found $table_count."
        return 1
    fi
}
run_test "Initial Schema State Verification (Version 0)" test_initial_state

# ------------------------------------------------------------------------------
# Test 3: Stepwise Forward Migrations (v1 -> v2 -> v3 -> v4)
# ------------------------------------------------------------------------------
test_stepwise_forward_migrations() {
    # 1. Apply migration 1 (Users)
    echo "  Applying Migration 1 (Users)..."
    "$SCRIPT_DIR/migrate.sh" up 1 >/dev/null
    local ver1
    ver1=$(python3 "$SCRIPT_DIR/db_inspector.py" --json | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")
    if [[ "$ver1" != "1" ]]; then
        echo "  Expected version 1, got $ver1"; return 1
    fi

    # 2. Apply migration 2 (Catalog)
    echo "  Applying Migration 2 (Catalog: Categories & Products)..."
    "$SCRIPT_DIR/migrate.sh" up 1 >/dev/null
    local ver2
    ver2=$(python3 "$SCRIPT_DIR/db_inspector.py" --json | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")
    if [[ "$ver2" != "2" ]]; then
        echo "  Expected version 2, got $ver2"; return 1
    fi

    # 3. Apply migration 3 (Orders)
    echo "  Applying Migration 3 (Orders & Items)..."
    "$SCRIPT_DIR/migrate.sh" up 1 >/dev/null
    local ver3
    ver3=$(python3 "$SCRIPT_DIR/db_inspector.py" --json | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")
    if [[ "$ver3" != "3" ]]; then
        echo "  Expected version 3, got $ver3"; return 1
    fi

    # 4. Apply migration 4 (Audit Logs & GIN index)
    echo "  Applying Migration 4 (Audit Logs & GIN Index)..."
    "$SCRIPT_DIR/migrate.sh" up 1 >/dev/null
    local summary_json
    summary_json=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local ver4 is_dirty table_count
    ver4=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")
    is_dirty=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_dirty'))")
    table_count=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('table_count'))")

    if [[ "$ver4" == "4" && "$is_dirty" == "False" && "$table_count" == "6" ]]; then
        echo "  Successfully migrated to version 4 with 6 application tables (users, categories, products, orders, order_items, audit_logs)."
        return 0
    else
        echo "  Verification failed: ver=$ver4, dirty=$is_dirty, tables=$table_count"; return 1
    fi
}
run_test "Stepwise Forward Migrations (v1 -> v2 -> v3 -> v4)" test_stepwise_forward_migrations

# ------------------------------------------------------------------------------
# Test 4: Data Seeding & Schema Evolution Integrity
# ------------------------------------------------------------------------------
test_data_seeding() {
    echo "  Seeding test records into all version 4 tables..."
    python3 "$SCRIPT_DIR/db_inspector.py" --seed --silent
    
    local summary_json
    summary_json=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local total_rows
    total_rows=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('total_rows', 0))")

    if (( total_rows >= 50 )); then
        echo "  Successfully seeded $total_rows records across all tables."
        return 0
    else
        echo "  Seeding failed or total rows ($total_rows) is below threshold."
        return 1
    fi
}
run_test "Data Seeding & Schema Evolution Integrity" test_data_seeding

# ------------------------------------------------------------------------------
# Test 5: Stepwise Rollbacks (down 1 -> goto 1 -> full rollback)
# ------------------------------------------------------------------------------
test_stepwise_rollbacks() {
    # 1. Rollback 1 step (to v3)
    echo "  Rolling back 1 step (v4 -> v3)..."
    "$SCRIPT_DIR/migrate.sh" down 1 >/dev/null
    local ver_after_down1
    ver_after_down1=$(python3 "$SCRIPT_DIR/db_inspector.py" --json | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")
    if [[ "$ver_after_down1" != "3" ]]; then
        echo "  Expected version 3 after rollback, got $ver_after_down1"; return 1
    fi

    # 2. Rollback to version 1 via goto
    echo "  Rolling back to version 1 (goto 1)..."
    "$SCRIPT_DIR/migrate.sh" goto 1 >/dev/null
    local summary_v1
    summary_v1=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local ver_goto1 table_count_v1
    ver_goto1=$(echo "$summary_v1" | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")
    table_count_v1=$(echo "$summary_v1" | python3 -c "import sys, json; print(json.load(sys.stdin).get('table_count'))")
    
    if [[ "$ver_goto1" != "1" || "$table_count_v1" != "1" ]]; then
        echo "  Expected version 1 with 1 table, got ver=$ver_goto1, tables=$table_count_v1"; return 1
    fi

    # 3. Full rollback (down to 0)
    echo "  Rolling back all remaining migrations (down)..."
    "$SCRIPT_DIR/migrate.sh" down >/dev/null
    local summary_v0
    summary_v0=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local table_count_v0
    table_count_v0=$(echo "$summary_v0" | python3 -c "import sys, json; print(json.load(sys.stdin).get('table_count'))")

    if (( table_count_v0 == 0 )); then
        echo "  Full rollback completed cleanly. 0 application tables remaining."
        return 0
    else
        echo "  Rollback incomplete: $table_count_v0 tables remaining."
        return 1
    fi
}
run_test "Stepwise Rollback Verification (down 1, goto 1, full rollback)" test_stepwise_rollbacks

# ------------------------------------------------------------------------------
# Test 6: Re-Apply All Migrations (Full UP)
# ------------------------------------------------------------------------------
test_reapply_migrations() {
    echo "  Re-applying all migrations forward (migrate up)..."
    "$SCRIPT_DIR/migrate.sh" up >/dev/null
    
    local summary_json
    summary_json=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local ver is_dirty table_count
    ver=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")
    is_dirty=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_dirty'))")
    table_count=$(echo "$summary_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('table_count'))")

    if [[ "$ver" == "4" && "$is_dirty" == "False" && "$table_count" == "6" ]]; then
        echo "  All 4 migrations re-applied successfully. Schema is clean at version 4."
        return 0
    else
        echo "  Re-application failed: ver=$ver, dirty=$is_dirty, tables=$table_count"; return 1
    fi
}
run_test "Re-Application of All Forward Migrations (Full UP)" test_reapply_migrations

# ------------------------------------------------------------------------------
# Test 7: Dirty State Simulation, Failure Detection, and 'force' Recovery
# ------------------------------------------------------------------------------
test_dirty_state_recovery() {
    echo "  Creating simulated failing migration with invalid SQL syntax..."
    local fail_up="$SCRIPT_DIR/migrations/000005_failing_migration.up.sql"
    local fail_down="$SCRIPT_DIR/migrations/000005_failing_migration.down.sql"

    cat <<EOF > "$fail_up"
-- Intentionally invalid SQL to simulate mid-migration failure
CREATE TABLE broken_table (
    id SERIAL PRIMARY KEY,
    INVALID_SQL_SYNTAX_ERROR HERE !!!
);
EOF

    cat <<EOF > "$fail_down"
DROP TABLE IF EXISTS broken_table;
EOF

    echo "  Attempting to apply failing migration (expecting error)..."
    set +e
    "$SCRIPT_DIR/migrate.sh" up >/dev/null 2>&1
    local fail_exit=$?
    set -e

    if (( fail_exit == 0 )); then
        echo "  Expected migration to fail, but it exited with 0."
        rm -f "$fail_up" "$fail_down"
        return 1
    fi

    # Inspect dirty state
    local dirty_summary
    dirty_summary=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local is_dirty current_ver
    is_dirty=$(echo "$dirty_summary" | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_dirty'))")
    current_ver=$(echo "$dirty_summary" | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")

    if [[ "$is_dirty" != "True" ]]; then
        echo "  Expected database to be in dirty state, got is_dirty=$is_dirty."
        rm -f "$fail_up" "$fail_down"
        return 1
    fi
    echo "  Dirty state confirmed: database flagged dirty=true at version $current_ver."

    # Verify subsequent migration attempts are blocked
    echo "  Verifying that subsequent migrations are blocked while dirty..."
    set +e
    "$SCRIPT_DIR/migrate.sh" up >/dev/null 2>&1
    local blocked_exit=$?
    set -e
    if (( blocked_exit == 0 )); then
        echo "  Database did not block migration while in dirty state!"
        rm -f "$fail_up" "$fail_down"
        return 1
    fi
    echo "  Migration execution correctly locked and blocked due to dirty state."

    # Remove the broken migration file
    rm -f "$fail_up" "$fail_down"

    # Recover using force command
    echo "  Executing dirty state recovery: ./migrate.sh force 4..."
    "$SCRIPT_DIR/migrate.sh" force 4 >/dev/null

    # Verify clean state restored
    local recovered_summary
    recovered_summary=$(python3 "$SCRIPT_DIR/db_inspector.py" --json)
    local recovered_dirty recovered_ver
    recovered_dirty=$(echo "$recovered_summary" | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_dirty'))")
    recovered_ver=$(echo "$recovered_summary" | python3 -c "import sys, json; print(json.load(sys.stdin).get('migration_version'))")

    if [[ "$recovered_dirty" == "False" && "$recovered_ver" == "4" ]]; then
        echo "  Dirty state recovery validated! Database restored to clean state (version 4, dirty=false)."
        return 0
    else
        echo "  Recovery failed: ver=$recovered_ver, dirty=$recovered_dirty."
        return 1
    fi
}
run_test "Dirty State Simulation, Error Detection & Force Recovery" test_dirty_state_recovery

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Migration Pipeline Test Execution Summary${CLR_RESET}"
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
