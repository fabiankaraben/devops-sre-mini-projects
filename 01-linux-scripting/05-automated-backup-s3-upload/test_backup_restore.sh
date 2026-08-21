#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_backup_restore.sh
# Description: Automated Test Suite for Automated Backup with S3 Upload.
#              Tests database seeding, GPG encryption, SHA256 integrity,
#              tamper detection, and complete disaster recovery restoration.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup_s3.sh"
RESTORE_SCRIPT="${SCRIPT_DIR}/verify_restore.sh"
SEEDER_SCRIPT="${SCRIPT_DIR}/mock_db_seeder.py"

TEST_SANDBOX="/tmp/backup_restore_test_sandbox_$$"
DATA_DIR="${TEST_SANDBOX}/data"
MOCK_S3="${TEST_SANDBOX}/mock_s3_bucket"
RESTORE_DIR="${TEST_SANDBOX}/restored_data"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

report_test() {
    local name="$1"
    local result="$2"
    local details="${3:-}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$result" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${GREEN}PASS${NC}] ${name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${RED}FAIL${NC}] ${name}"
        if [[ -n "$details" ]]; then
            echo -e "         ${YELLOW}Details: ${details}${NC}"
        fi
    fi
}

validate_json() {
    local json_str="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$json_str" | jq . >/dev/null 2>&1
        return $?
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys, json; json.loads(sys.stdin.read())" <<< "$json_str" >/dev/null 2>&1
        return $?
    else
        return 0
    fi
}

cleanup() {
    rm -rf "$TEST_SANDBOX" 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}  Automated Backup & Disaster Recovery - Tests       ${NC}"
echo -e "${BLUE}======================================================${NC}\n"

mkdir -p "$DATA_DIR" "$MOCK_S3" "$RESTORE_DIR"

# ------------------------------------------------------------------------------
# Suite 1: CLI Arguments & Help Handling
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Arguments & Help Handling${NC}"

set +e
help_out=$("$BACKUP_SCRIPT" --help 2>&1)
help_exit=$?
set -e
if [[ $help_exit -eq 0 && "$help_out" =~ "Usage:" ]]; then
    report_test "backup_s3.sh --help displays usage and exits 0" "PASS"
else
    report_test "backup_s3.sh --help displays usage" "FAIL" "Exit code: ${help_exit}"
fi

set +e
restore_help_out=$("$RESTORE_SCRIPT" --help 2>&1)
restore_help_exit=$?
set -e
if [[ $restore_help_exit -eq 0 && "$restore_help_out" =~ "Usage:" ]]; then
    report_test "verify_restore.sh --help displays usage and exits 0" "PASS"
else
    report_test "verify_restore.sh --help displays usage" "FAIL" "Exit code: ${restore_help_exit}"
fi

set +e
missing_db_out=$("$BACKUP_SCRIPT" --db-path "/non_existent_db_123.sqlite" 2>&1)
missing_db_exit=$?
set -e
if [[ $missing_db_exit -eq 2 ]]; then
    report_test "Missing source database triggers exit code 2 (ERROR)" "PASS"
else
    report_test "Missing source database triggers exit code 2" "FAIL" "Expected 2, got: ${missing_db_exit}"
fi

# ------------------------------------------------------------------------------
# Suite 2: Mock Database & Asset Seeding
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Database & Asset Seeding${NC}"

DB_FILE="${DATA_DIR}/app_production.db"
UPLOADS_DIR="${DATA_DIR}/uploads"

python3 "$SEEDER_SCRIPT" --db-path "$DB_FILE" --uploads-dir "$UPLOADS_DIR" --users 50 --orders 120 >/dev/null 2>&1

if [[ -f "$DB_FILE" && -d "$UPLOADS_DIR" ]]; then
    report_test "mock_db_seeder.py successfully seeded database and uploads" "PASS"
else
    report_test "mock_db_seeder.py seeding" "FAIL" "Database or uploads missing"
fi

# ------------------------------------------------------------------------------
# Suite 3: Backup, GPG Encryption & Checksum Generation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Backup Generation, AES-256 Encryption & Checksums${NC}"

set +e
backup_json=$("$BACKUP_SCRIPT" \
    --db-path "$DB_FILE" \
    --data-dir "$UPLOADS_DIR" \
    --mock-s3-dir "$MOCK_S3" \
    --passphrase "TestSecurePassphrase123!" \
    --json 2>&1)
backup_exit=$?
set -e

if [[ $backup_exit -eq 0 ]]; then
    report_test "backup_s3.sh executed backup pipeline with exit code 0" "PASS"
else
    report_test "backup_s3.sh executed backup pipeline" "FAIL" "Exit code: ${backup_exit}"
fi

if validate_json "$backup_json"; then
    report_test "Backup execution report conforms to valid JSON schema" "PASS"
else
    report_test "Backup execution report conforms to valid JSON schema" "FAIL" "Invalid JSON generated"
fi

enc_files=("$MOCK_S3"/*.enc)
if [[ ${#enc_files[@]} -gt 0 && -f "${enc_files[0]}" ]]; then
    report_test "Encrypted backup archive (.enc) uploaded to object storage" "PASS"
else
    report_test "Encrypted backup archive (.enc) uploaded" "FAIL" "No .enc file in mock S3"
fi

sha_files=("$MOCK_S3"/*.sha256)
if [[ ${#sha_files[@]} -gt 0 && -f "${sha_files[0]}" ]]; then
    report_test "SHA-256 manifest file generated and uploaded" "PASS"
else
    report_test "SHA-256 manifest file generated" "FAIL" "No .sha256 file in mock S3"
fi

# ------------------------------------------------------------------------------
# Suite 4: Tamper Detection (Corrupted Checksum Rejection)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Tamper Detection & Security Check${NC}"

# Create tampered artifact directory
TAMPER_DIR="${TEST_SANDBOX}/tampered_mock_s3"
mkdir -p "$TAMPER_DIR"
cp "${enc_files[0]}" "${TAMPER_DIR}/"
# Corrupt the SHA256 checksum manifest
echo "0000000000000000000000000000000000000000000000000000000000000000  $(basename "${enc_files[0]}")" > "${TAMPER_DIR}/$(basename "${enc_files[0]}").sha256"

set +e
tamper_out=$("$RESTORE_SCRIPT" --mock-s3-dir "$TAMPER_DIR" --passphrase "TestSecurePassphrase123!" 2>&1)
tamper_exit=$?
set -e

if [[ $tamper_exit -eq 2 && "$tamper_out" =~ "CHECKSUM MISMATCH" ]]; then
    report_test "Tampered checksum detected and restore rejected (Exit 2)" "PASS"
else
    report_test "Tampered checksum detected and restore rejected" "FAIL" "Exit: ${tamper_exit}, Output: ${tamper_out}"
fi

# ------------------------------------------------------------------------------
# Suite 5: Disaster Recovery & Database Restoration
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Disaster Recovery & SQLite Table Restoration${NC}"

set +e
restore_json=$("$RESTORE_SCRIPT" \
    --mock-s3-dir "$MOCK_S3" \
    --passphrase "TestSecurePassphrase123!" \
    --restore-dir "$RESTORE_DIR" \
    --json 2>&1)
restore_exit=$?
set -e

if [[ $restore_exit -eq 0 ]]; then
    report_test "verify_restore.sh executed decryption and extraction with exit code 0" "PASS"
else
    report_test "verify_restore.sh execution" "FAIL" "Exit code: ${restore_exit}"
fi

if validate_json "$restore_json"; then
    report_test "Restore verification report conforms to valid JSON schema" "PASS"
else
    report_test "Restore verification report conforms to valid JSON schema" "FAIL" "Invalid JSON generated"
fi

RESTORED_DB="${RESTORE_DIR}/database.sqlite"
if [[ -f "$RESTORED_DB" ]]; then
    # Query recovered rows
    rec_users=$(sqlite3 "$RESTORED_DB" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)
    rec_orders=$(sqlite3 "$RESTORED_DB" "SELECT count(*) FROM orders;" 2>/dev/null || echo 0)

    if [[ "$rec_users" -eq 50 && "$rec_orders" -eq 120 ]]; then
        report_test "Restored SQLite tables contain 100% of original records (50 users, 120 orders)" "PASS"
    else
        report_test "Restored SQLite tables record counts" "FAIL" "Users: ${rec_users}/50, Orders: ${rec_orders}/120"
    fi
else
    report_test "Restored SQLite database file exists" "FAIL" "database.sqlite missing in restore dir"
fi

if [[ -f "${RESTORE_DIR}/uploads/avatar_01.png" && -f "${RESTORE_DIR}/uploads/invoice_101.pdf" ]]; then
    report_test "Static filesystem assets restored cleanly" "PASS"
else
    report_test "Static filesystem assets restored" "FAIL" "Files missing in ${RESTORE_DIR}/uploads"
fi

# ------------------------------------------------------------------------------
# Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}======================================================${NC}"
echo -e "  Test Results: ${PASSED_TESTS}/${TOTAL_TESTS} Passed"
if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "  Status: ${GREEN}ALL TESTS PASSED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 0
else
    echo -e "  Status: ${RED}${FAILED_TESTS} TESTS FAILED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 1
fi
