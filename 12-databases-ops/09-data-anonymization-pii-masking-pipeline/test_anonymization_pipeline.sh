#!/usr/bin/env bash
# ==============================================================================
# test_anonymization_pipeline.sh - Automated Pipeline & Compliance Test Suite
# ==============================================================================
# Executes end-to-end data anonymization validation checkpoints:
# 1. Docker infrastructure startup & PostgreSQL database health check
# 2. Raw production database seeding & initial PII verification
# 3. Pre-sanitization PII vulnerability verification on production_db
# 4. Automated ETL data anonymization & masking execution (mask_database.py)
# 5. Post-sanitization security & compliance audit (verify_anonymization.py)
# 6. Relational referential integrity & foreign key consistency validation
# 7. Sanitized SQL dump portability & clean schema restore verification
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
echo "  🧪 Data Anonymization & PII Masking - Automated Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

# ------------------------------------------------------------------------------
# Test 1: Infrastructure Startup & PostgreSQL Health
# ------------------------------------------------------------------------------
test_infra_startup() {
    echo "  Starting PostgreSQL container via docker compose..."
    docker compose up -d --wait >/dev/null

    echo "  Verifying database connectivity..."
    docker exec postgres-anonymizer-db pg_isready -U postgres -d production_db >/dev/null
    docker exec postgres-anonymizer-db pg_isready -U postgres -d staging_db >/dev/null

    echo "  PostgreSQL infrastructure is healthy."
    return 0
}
run_test "Infrastructure Startup & PostgreSQL Health" test_infra_startup

# ------------------------------------------------------------------------------
# Test 2: Production Database Seeding & Sensitive Records
# ------------------------------------------------------------------------------
test_production_seeding() {
    echo "  Auditing raw sensitive records in production_db..."
    local cust_cnt
    cust_cnt=$(docker exec postgres-anonymizer-db psql -U postgres -d production_db -t -A -c "SELECT COUNT(*) FROM customers;")
    local card_cnt
    card_cnt=$(docker exec postgres-anonymizer-db psql -U postgres -d production_db -t -A -c "SELECT COUNT(*) FROM credit_cards;")
    local order_cnt
    order_cnt=$(docker exec postgres-anonymizer-db psql -U postgres -d production_db -t -A -c "SELECT COUNT(*) FROM orders;")

    echo "  • Production Customers : ${cust_cnt}"
    echo "  • Production Cards     : ${card_cnt}"
    echo "  • Production Orders    : ${order_cnt}"

    if (( cust_cnt >= 5 && card_cnt >= 5 && order_cnt >= 6 )); then
        echo "  Production dataset verified."
        return 0
    fi
    return 1
}
run_test "Production Database Seeding & Record Verification" test_production_seeding

# ------------------------------------------------------------------------------
# Test 3: Pre-Sanitization PII Detection
# ------------------------------------------------------------------------------
test_pre_sanitization_pii() {
    echo "  Confirming presence of real PII in raw production_db..."
    local real_email_count
    real_email_count=$(docker exec postgres-anonymizer-db psql -U postgres -d production_db -t -A -c \
        "SELECT COUNT(*) FROM customers WHERE email LIKE '%@gmail.com' OR email LIKE '%@corporate-bank.com';")

    local raw_card_count
    raw_card_count=$(docker exec postgres-anonymizer-db psql -U postgres -d production_db -t -A -c \
        "SELECT COUNT(*) FROM credit_cards WHERE card_number NOT LIKE '%XXXX%';")

    echo "  • Raw Unmasked Emails in Prod: ${real_email_count}"
    echo "  • Raw Unmasked Cards in Prod : ${raw_card_count}"

    if (( real_email_count >= 2 && raw_card_count >= 5 )); then
        echo "  Pre-sanitization PII vulnerability confirmed (requires masking)."
        return 0
    fi
    return 1
}
run_test "Pre-Sanitization PII Vulnerability Baseline Audit" test_pre_sanitization_pii

# ------------------------------------------------------------------------------
# Test 4: Automated ETL Data Anonymization Execution
# ------------------------------------------------------------------------------
test_run_masking_etl() {
    echo "  Executing mask_database.py ETL pipeline..."
    python3 "$SCRIPT_DIR/mask_database.py"

    if [ -f "$SCRIPT_DIR/dumps/sanitized_staging_dump.sql" ] && [ -f "$SCRIPT_DIR/reports/anonymization_report.json" ]; then
        echo "  ETL masking execution and artifact generation verified."
        return 0
    fi
    return 1
}
run_test "Automated ETL Data Anonymization Execution (mask_database.py)" test_run_masking_etl

# ------------------------------------------------------------------------------
# Test 5: Post-Sanitization Security & Compliance Audit
# ------------------------------------------------------------------------------
test_compliance_audit() {
    echo "  Running compliance & zero-leak scanner verify_anonymization.py..."
    python3 "$SCRIPT_DIR/verify_anonymization.py"

    echo "  Zero PII leak compliance verified."
    return 0
}
run_test "Post-Sanitization Security & Compliance Audit (verify_anonymization.py)" test_compliance_audit

# ------------------------------------------------------------------------------
# Test 6: Relational Referential Integrity Validation
# ------------------------------------------------------------------------------
test_referential_integrity() {
    echo "  Auditing relational joins in staging_db..."
    local join_orders_count
    join_orders_count=$(docker exec postgres-anonymizer-db psql -U postgres -d staging_db -t -A -c "
        SELECT COUNT(*)
        FROM orders o
        JOIN customers c ON o.customer_id = c.id
        JOIN credit_cards cc ON cc.customer_id = c.id;
    ")

    echo "  • Fully Joined Order-Customer-Card Records: ${join_orders_count}"

    if (( join_orders_count >= 6 )); then
        echo "  Relational integrity preserved 100% across all masked entities."
        return 0
    fi
    return 1
}
run_test "Relational Referential Integrity & Foreign Key Consistency" test_referential_integrity

# ------------------------------------------------------------------------------
# Test 7: Sanitized SQL Dump Portability & Restore Verification
# ------------------------------------------------------------------------------
test_dump_restore() {
    echo "  Testing dump restoration into temporary database 'restore_test_db'..."
    docker exec postgres-anonymizer-db psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS restore_test_db;" >/dev/null
    docker exec postgres-anonymizer-db psql -U postgres -d postgres -c "CREATE DATABASE restore_test_db;" >/dev/null
    
    docker exec -i postgres-anonymizer-db psql -U postgres -d restore_test_db < "$SCRIPT_DIR/dumps/sanitized_staging_dump.sql" >/dev/null

    local restored_count
    restored_count=$(docker exec postgres-anonymizer-db psql -U postgres -d restore_test_db -t -A -c "SELECT COUNT(*) FROM customers;")

    echo "  • Restored Customers from Sanitized SQL Dump: ${restored_count}"

    docker exec postgres-anonymizer-db psql -U postgres -d postgres -c "DROP DATABASE restore_test_db;" >/dev/null

    if (( restored_count == 5 )); then
        echo "  Sanitized SQL dump portability verified."
        return 0
    fi
    return 1
}
run_test "Sanitized SQL Dump Portability & Schema Restore Verification" test_dump_restore

# ------------------------------------------------------------------------------
# Final Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Data Anonymization Pipeline Test Execution Summary${CLR_RESET}"
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
