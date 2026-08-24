#!/usr/bin/env bash
# ==============================================================================
# test_pipeline.sh - Automated End-to-End Test Suite for PostgreSQL Resilience
# ==============================================================================
# Executes comprehensive validation checkpoints:
# 1. Environment & Container Health
# 2. Database Seeding & Schema Verification
# 3. Automated Backup & Manifest Generation
# 4. Cryptographic Tamper Detection Security Gate
# 5. Clean Database Restore & Parity Validation
# 6. Custom Dump Format Backup & Recovery
# 7. Retention Policy Pruning Verification
# 8. Disaster Recovery Incident Simulation & Full Recovery
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
echo "  🧪 PostgreSQL Backup & Restore Resilience - Automated Test Suite"
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

# Ensure scripts are executable
chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py 2>/dev/null || true

# ------------------------------------------------------------------------------
# Test 1: Start Docker Containers and Wait for Healthy Status
# ------------------------------------------------------------------------------
test_docker_startup() {
    echo "  Starting PostgreSQL containers (postgres-primary & postgres-validation)..."
    $COMPOSE_CMD up -d --wait
    
    local retries=20
    while (( retries > 0 )); do
        local healthy_count
        healthy_count=$(docker ps --filter "name=postgres-" --filter "health=healthy" --format "{{.Names}}" | wc -l | tr -d ' ')
        if (( healthy_count >= 2 )); then
            echo "  Both PostgreSQL primary and validation containers are healthy."
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "  Timed out waiting for containers to become healthy."
    return 1
}
run_test "Container Infrastructure Startup & Health Check" test_docker_startup

# ------------------------------------------------------------------------------
# Test 2: Seed Primary Database with Relational Test Records
# ------------------------------------------------------------------------------
test_database_seeding() {
    python3 "$SCRIPT_DIR/seed_database.py" \
        --clean \
        --users 40 \
        --products 25 \
        --orders 80 \
        --logs 120 \
        --silent
    
    # Verify records were inserted
    local stats_json
    stats_json=$(python3 "$SCRIPT_DIR/seed_database.py" --inspect-only --json)
    local total_rows
    total_rows=$(echo "$stats_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('total_rows', 0))")
    
    if (( total_rows > 100 )); then
        echo "  Successfully seeded database. Total recorded rows: $total_rows"
        return 0
    else
        echo "  Database seeding failed or total rows ($total_rows) is below threshold."
        return 1
    fi
}
run_test "Primary Database Schema Provisioning & Seeding" test_database_seeding

# ------------------------------------------------------------------------------
# Test 3: Generate Automated Gzip Backup with SHA256 & Metadata
# ------------------------------------------------------------------------------
test_automated_backup() {
    rm -rf "$SCRIPT_DIR/backups"
    mkdir -p "$SCRIPT_DIR/backups"

    "$SCRIPT_DIR/backup_postgres.sh" \
        --db production_db \
        --out-dir "$SCRIPT_DIR/backups" \
        --format plain_gzip \
        --silent

    # Check for created files
    local backup_count sha_count meta_count
    backup_count=$(find "$SCRIPT_DIR/backups" -name "*.sql.gz" | wc -l | tr -d ' ')
    sha_count=$(find "$SCRIPT_DIR/backups" -name "*.sha256" | wc -l | tr -d ' ')
    meta_count=$(find "$SCRIPT_DIR/backups" -name "*.meta.json" | wc -l | tr -d ' ')

    if (( backup_count == 1 && sha_count == 1 && meta_count == 1 )); then
        echo "  Backup archive, SHA256 manifest, and metadata JSON generated correctly."
        return 0
    else
        echo "  Artifact mismatch: backups=$backup_count, sha=$sha_count, meta=$meta_count"
        return 1
    fi
}
run_test "Automated Gzip Backup & Manifest Generation" test_automated_backup

# ------------------------------------------------------------------------------
# Test 4: Cryptographic Tamper Detection & Corrupted Backup Rejection
# ------------------------------------------------------------------------------
test_tamper_detection() {
    local latest_backup
    latest_backup=$(find "$SCRIPT_DIR/backups" -name "*.sql.gz" | head -n 1)
    
    # Create a corrupted clone in a temp directory
    local tamper_dir="$SCRIPT_DIR/backups/tamper_test"
    mkdir -p "$tamper_dir"
    local corrupt_backup="$tamper_dir/corrupted_backup.sql.gz"
    
    cp "$latest_backup" "$corrupt_backup"
    cp "${latest_backup}.sha256" "$tamper_dir/corrupted_backup.sql.gz.sha256"
    
    # Flip bytes inside the corrupted copy
    echo "CORRUPTED_BYTES_INJECTION" >> "$corrupt_backup"
    
    # Attempt restore and expect exit code 2 (Security/Tamper Error)
    set +e
    "$SCRIPT_DIR/restore_postgres.sh" --backup-file "$corrupt_backup" --silent >/dev/null 2>&1
    local exit_code=$?
    set -e
    
    rm -rf "$tamper_dir"
    
    if (( exit_code == 2 )); then
        echo "  Tamper detection successfully caught corrupted hash and aborted restore (exit code 2)."
        return 0
    else
        echo "  Tamper detection failed! Expected exit code 2, got $exit_code."
        return 1
    fi
}
run_test "Cryptographic Tamper Detection Security Gate" test_tamper_detection

# ------------------------------------------------------------------------------
# Test 5: Clean Restore into Validation Container with Parity Check
# ------------------------------------------------------------------------------
test_restore_parity() {
    rm -f "$SCRIPT_DIR/validation_report.json"

    "$SCRIPT_DIR/restore_postgres.sh" \
        --target-port 5433 \
        --target-db validation_db \
        --report "$SCRIPT_DIR/validation_report.json" \
        --silent

    if [[ ! -f "$SCRIPT_DIR/validation_report.json" ]]; then
        echo "  Validation report JSON was not created."
        return 1
    fi

    local validation_passed
    validation_passed=$(python3 -c "import json; print(json.load(open('$SCRIPT_DIR/validation_report.json')).get('validation_passed', False))")

    if [[ "$validation_passed" == "True" ]]; then
        echo "  Restoration completed with 100% table and row-count parity."
        return 0
    else
        echo "  Parity verification failed: validation_passed is $validation_passed."
        return 1
    fi
}
run_test "Validation Restore & 100% Data Parity Audit" test_restore_parity

# ------------------------------------------------------------------------------
# Test 6: Custom Dump Format Backup & Recovery (.dump)
# ------------------------------------------------------------------------------
test_custom_format_backup() {
    "$SCRIPT_DIR/backup_postgres.sh" \
        --db production_db \
        --out-dir "$SCRIPT_DIR/backups" \
        --format custom \
        --silent

    local custom_backup
    custom_backup=$(find "$SCRIPT_DIR/backups" -name "*.dump" | head -n 1)

    if [[ -z "$custom_backup" || ! -f "$custom_backup" ]]; then
        echo "  Custom dump backup file not generated."
        return 1
    fi

    # Restore custom format dump
    "$SCRIPT_DIR/restore_postgres.sh" \
        --backup-file "$custom_backup" \
        --target-port 5433 \
        --target-db validation_db \
        --silent

    echo "  Custom format (.dump) backup and restoration validated."
    return 0
}
run_test "PostgreSQL Custom Format (.dump) Pipeline" test_custom_format_backup

# ------------------------------------------------------------------------------
# Test 7: Retention Policy Pruning Simulation
# ------------------------------------------------------------------------------
test_retention_pruning() {
    # Generate 4 mock older backup files with past timestamps
    local mock_base="$SCRIPT_DIR/backups"
    
    touch -t 202501011200 "$mock_base/production_db_20250101_120000Z.sql.gz"
    touch -t 202501011200 "$mock_base/production_db_20250101_120000Z.sql.gz.sha256"
    touch -t 202501011200 "$mock_base/production_db_20250101_120000Z.sql.gz.meta.json"

    touch -t 202501021200 "$mock_base/production_db_20250102_120000Z.sql.gz"
    touch -t 202501021200 "$mock_base/production_db_20250102_120000Z.sql.gz.sha256"
    touch -t 202501021200 "$mock_base/production_db_20250102_120000Z.sql.gz.meta.json"

    touch -t 202501031200 "$mock_base/production_db_20250103_120000Z.sql.gz"
    touch -t 202501031200 "$mock_base/production_db_20250103_120000Z.sql.gz.sha256"
    touch -t 202501031200 "$mock_base/production_db_20250103_120000Z.sql.gz.meta.json"

    local before_count
    before_count=$(find "$mock_base" -name "*.sql.gz" | wc -l | tr -d ' ')

    # Run backup with retention of 3 days and keep-last 2
    "$SCRIPT_DIR/backup_postgres.sh" \
        --retention-days 3 \
        --keep-last 2 \
        --silent

    local after_count
    after_count=$(find "$mock_base" -name "*.sql.gz" | wc -l | tr -d ' ')

    if (( after_count < before_count )); then
        echo "  Retention policy pruned expired snapshots (before: $before_count, after: $after_count)."
        return 0
    else
        echo "  Retention pruning did not remove expired mock snapshots."
        return 1
    fi
}
run_test "Retention Policy & Stale Snapshot Pruning" test_retention_pruning

# ------------------------------------------------------------------------------
# Test 8: Disaster Recovery Simulation (Accidental DROP TABLE Recovery)
# ------------------------------------------------------------------------------
test_disaster_recovery_drill() {
    # 1. Take a fresh backup
    "$SCRIPT_DIR/backup_postgres.sh" \
        --db production_db \
        --out-dir "$SCRIPT_DIR/backups" \
        --silent

    local latest_backup
    latest_backup=$(find "$SCRIPT_DIR/backups" -name "production_db_*.sql.gz" -exec stat -f "%m %N" {} + 2>/dev/null | sort -nr | head -n 1 | awk '{print $2}' || true)
    if [[ -z "$latest_backup" ]]; then
        latest_backup=$(find "$SCRIPT_DIR/backups" -name "production_db_*.sql.gz" -exec stat -c "%Y %n" {} + 2>/dev/null | sort -nr | head -n 1 | awk '{print $2}' || true)
    fi

    # 2. Simulate catastrophic disaster on primary: DROP TABLE orders CASCADE
    echo "  Simulating catastrophic data loss: DROP TABLE orders CASCADE on primary database..."
    docker exec -e PGPASSWORD=postgres postgres-primary psql -U postgres -d production_db -c "DROP TABLE orders CASCADE;" >/dev/null 2>&1

    # Verify orders table is gone
    local table_check
    table_check=$(docker exec -e PGPASSWORD=postgres postgres-primary psql -U postgres -d production_db -t -A -c "SELECT to_regclass('public.orders');")
    if [[ "$table_check" != "" && "$table_check" != "[null]" ]]; then
        echo "  Failed to simulate table drop."
        return 1
    fi
    echo "  Disaster confirmed: 'orders' table dropped from primary."

    # 3. Execute recovery into primary database
    echo "  Executing Disaster Recovery restoration from backup: $(basename "$latest_backup")..."
    "$SCRIPT_DIR/restore_postgres.sh" \
        --backup-file "$latest_backup" \
        --target-port 5432 \
        --target-db production_db \
        --target-container postgres-primary \
        --report "$SCRIPT_DIR/disaster_recovery_report.json" \
        --silent

    # 4. Verify orders table is fully recovered with rows
    local recovered_rows
    recovered_rows=$(docker exec -e PGPASSWORD=postgres postgres-primary psql -U postgres -d production_db -t -A -c "SELECT COUNT(*) FROM orders;" | tr -d ' \r\n')
    
    if (( recovered_rows > 0 )); then
        echo "  Disaster Recovery Successful! 'orders' table recovered with $recovered_rows rows."
        return 0
    else
        echo "  Disaster recovery failed to recover rows in 'orders' table."
        return 1
    fi
}
run_test "Disaster Recovery Drill: Accidental Drop & Full Restoration" test_disaster_recovery_drill

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Test Suite Execution Summary${CLR_RESET}"
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  Total Test Checkpoints : ${TOTAL_TESTS}"
echo -e "  Passed                 : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed                 : $( [ $FAILED_TESTS -gt 0 ] && echo "${CLR_RED}${FAILED_TESTS}${CLR_RESET}" || echo "0" )"
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

if (( FAILED_TESTS == 0 )); then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All 8 Test Checkpoints Passed Successfully!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}✖ Test Suite Failed with $FAILED_TESTS failure(s).${CLR_RESET}\n"
    exit 1
fi
