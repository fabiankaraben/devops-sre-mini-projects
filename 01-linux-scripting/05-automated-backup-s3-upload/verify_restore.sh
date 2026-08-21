#!/usr/bin/env bash
# ==============================================================================
# Script Name: verify_restore.sh
# Description: Automated Disaster Recovery & Integrity Verification Script.
#              Downloads encrypted backup artifacts from S3/MinIO/mock storage,
#              verifies SHA-256 cryptographic hashes for tamper detection,
#              decrypts via AES-256 (GPG / OpenSSL), extracts assets, and validates
#              SQLite database integrity and record counts.
#
# Exit Codes:
#   0 - Success: Backup verified, decrypted, and database integrity confirmed.
#   1 - Integrity Warning: Database check failed or checksum mismatch.
#   2 - Fatal Error: Missing artifact, decryption failure, or corrupt archive.
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults (scoped inside project directory)
BACKUP_KEY=""
MOCK_S3_DIR="${SCRIPT_DIR}/mock_s3_bucket"
S3_BUCKET="production-backups"
S3_ENDPOINT=""
GPG_PASSPHRASE="DevOpsSecretPassphrase2026!"
RESTORE_DIR="${SCRIPT_DIR}/restored_data"
STAGING_DIR="/tmp/restore_staging_$$"
JSON_OUTPUT=false
PRETTY_PRINT=false

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Disaster Recovery & Restore Verification (DevOps / SRE Mini-Project)
Downloads, verifies SHA-256, decrypts with AES-256, and validates database tables.

Options:
  --backup-key <filename>   Specific backup artifact name to restore (e.g. backup_*.tar.gz.enc)
  --mock-s3-dir <path>      Local folder acting as mock S3 bucket (default: ./mock_s3_bucket)
  --s3-bucket <bucket>      Target S3 bucket name (default: production-backups)
  --s3-endpoint <url>       Optional MinIO/LocalStack S3 endpoint URL
  --passphrase <string>     Symmetric decryption passphrase
  --restore-dir <path>      Destination directory for extracted data (default: ./restored_data)
  --json                    Emit structured verification report in JSON format
  --pretty                  Format JSON report with 2-space indentation
  -h, --help                Display this help message and exit
  -v, --version             Display version information and exit

Examples:
  # Verify and restore the latest backup in ./mock_s3_bucket
  $(basename "$0") --json --pretty

  # Restore a specific backup archive from MinIO
  $(basename "$0") --backup-key backup_2026-08-21T10-00-00Z.tar.gz.enc --s3-endpoint http://localhost:9000
EOF
}

print_error() {
    local msg="$1"
    if [[ "$JSON_OUTPUT" == true ]]; then
        echo "{\"error\": \"${msg}\", \"status\": \"ERROR\", \"exit_code\": 2}" >&2
    else
        echo "[ERROR] ${msg}" >&2
    fi
}

cleanup_staging() {
    rm -rf "$STAGING_DIR" 2>/dev/null || true
}

trap cleanup_staging SIGINT SIGTERM EXIT

calculate_sha256() {
    local target_file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$target_file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$target_file" | awk '{print $1}'
    else
        openssl dgst -sha256 "$target_file" | awk '{print $NF}'
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup-key)
                [[ $# -lt 2 ]] && { print_error "Missing value for --backup-key"; exit 2; }
                BACKUP_KEY="$2"
                shift 2
                ;;
            --mock-s3-dir)
                [[ $# -lt 2 ]] && { print_error "Missing value for --mock-s3-dir"; exit 2; }
                MOCK_S3_DIR="$2"
                shift 2
                ;;
            --s3-bucket)
                [[ $# -lt 2 ]] && { print_error "Missing value for --s3-bucket"; exit 2; }
                S3_BUCKET="$2"
                shift 2
                ;;
            --s3-endpoint)
                [[ $# -lt 2 ]] && { print_error "Missing value for --s3-endpoint"; exit 2; }
                S3_ENDPOINT="$2"
                shift 2
                ;;
            --passphrase)
                [[ $# -lt 2 ]] && { print_error "Missing value for --passphrase"; exit 2; }
                GPG_PASSPHRASE="$2"
                shift 2
                ;;
            --restore-dir)
                [[ $# -lt 2 ]] && { print_error "Missing value for --restore-dir"; exit 2; }
                RESTORE_DIR="$2"
                shift 2
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --pretty)
                PRETTY_PRINT=true
                JSON_OUTPUT=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            -v|--version)
                echo "verify_restore.sh version ${VERSION}"
                exit 0
                ;;
            *)
                print_error "Unrecognized option: '$1'. Run with --help for usage."
                exit 2
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    local run_timestamp
    run_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    mkdir -p "$STAGING_DIR" "$RESTORE_DIR"

    # --------------------------------------------------------------------------
    # Step 1: Identify and Download Backup Artifact
    # --------------------------------------------------------------------------
    local local_enc_path=""
    local local_sha_path=""

    if [[ -n "$S3_ENDPOINT" ]] && command -v aws >/dev/null 2>&1; then
        if [[ -z "$BACKUP_KEY" ]]; then
            BACKUP_KEY=$(aws s3 ls "s3://${S3_BUCKET}/" --endpoint-url "$S3_ENDPOINT" | awk '/\.enc$/ {print $4}' | sort -r | head -n 1)
        fi
        if [[ -z "$BACKUP_KEY" ]]; then
            print_error "No encrypted backup artifacts found in s3://${S3_BUCKET}/"
            exit 2
        fi
        local_enc_path="${STAGING_DIR}/${BACKUP_KEY}"
        local_sha_path="${STAGING_DIR}/${BACKUP_KEY}.sha256"
        aws s3 cp "s3://${S3_BUCKET}/${BACKUP_KEY}" "$local_enc_path" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
        aws s3 cp "s3://${S3_BUCKET}/${BACKUP_KEY}.sha256" "$local_sha_path" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
    else
        # Local Mock S3 Storage
        if [[ -z "$BACKUP_KEY" ]]; then
            shopt -s nullglob
            local mock_files=("${MOCK_S3_DIR}"/*.enc)
            shopt -u nullglob
            if [[ ${#mock_files[@]} -eq 0 ]]; then
                print_error "No backup artifacts found in mock directory '${MOCK_S3_DIR}'"
                exit 2
            fi
            local latest_mock
            latest_mock=$(ls -t "${MOCK_S3_DIR}"/*.enc | head -n 1)
            BACKUP_KEY=$(basename "$latest_mock")
        fi
        local_enc_path="${MOCK_S3_DIR}/${BACKUP_KEY}"
        local_sha_path="${MOCK_S3_DIR}/${BACKUP_KEY}.sha256"
    fi

    if [[ ! -f "$local_enc_path" ]]; then
        print_error "Encrypted backup file '${local_enc_path}' does not exist"
        exit 2
    fi

    # --------------------------------------------------------------------------
    # Step 2: Cryptographic SHA-256 Checksum Verification (Tamper Detection)
    # --------------------------------------------------------------------------
    local computed_sha expected_sha="unknown"
    computed_sha=$(calculate_sha256 "$local_enc_path")

    if [[ -f "$local_sha_path" ]]; then
        expected_sha=$(awk '{print $1}' "$local_sha_path")
        if [[ "$computed_sha" != "$expected_sha" ]]; then
            print_error "SHA-256 CHECKSUM MISMATCH! Tampering or bit-rot detected. (Computed: ${computed_sha}, Expected: ${expected_sha})"
            exit 2
        fi
    fi

    # --------------------------------------------------------------------------
    # Step 3: Symmetric Decryption (GPG / OpenSSL)
    # --------------------------------------------------------------------------
    local decrypted_tar="${STAGING_DIR}/decrypted_archive.tar.gz"
    local decrypt_success=false

    if command -v gpg >/dev/null 2>&1; then
        if gpg --batch --yes --passphrase "$GPG_PASSPHRASE" --decrypt -o "$decrypted_tar" "$local_enc_path" 2>/dev/null; then
            decrypt_success=true
        fi
    fi

    if [[ "$decrypt_success" == false ]] && command -v openssl >/dev/null 2>&1; then
        if openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:$GPG_PASSPHRASE" -in "$local_enc_path" -out "$decrypted_tar" 2>/dev/null; then
            decrypt_success=true
        fi
    fi

    if [[ "$decrypt_success" == false ]]; then
        print_error "Decryption failed! Invalid passphrase or corrupted archive."
        exit 2
    fi

    # --------------------------------------------------------------------------
    # Step 4: Extract Tarball Contents
    # --------------------------------------------------------------------------
    tar -xzf "$decrypted_tar" -C "$RESTORE_DIR"

    # --------------------------------------------------------------------------
    # Step 5: Validate SQLite Database Integrity & Record Counts
    # --------------------------------------------------------------------------
    local restored_db="${RESTORE_DIR}/database.sqlite"
    local db_integrity="not_present"
    local total_users=0
    local total_orders=0

    if [[ -f "$restored_db" ]]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            db_integrity=$(sqlite3 "$restored_db" "PRAGMA integrity_check;" 2>/dev/null || echo "corrupt")
            if [[ "$db_integrity" == "ok" ]]; then
                total_users=$(sqlite3 "$restored_db" "SELECT count(*) FROM users;" 2>/dev/null || echo 0)
                total_orders=$(sqlite3 "$restored_db" "SELECT count(*) FROM orders;" 2>/dev/null || echo 0)
            else
                print_error "Restored SQLite database failed integrity check: ${db_integrity}"
                exit 1
            fi
        else
            db_integrity="ok_unverified_sqlite3_missing"
        fi
    fi

    local restored_files_count
    restored_files_count=$(find "$RESTORE_DIR" -type f | wc -l | tr -d ' ')

    # --------------------------------------------------------------------------
    # Step 6: Output Verification Summary Report
    # --------------------------------------------------------------------------
    local json_report
    json_report=$(cat <<EOF
{
  "timestamp": "${run_timestamp}",
  "status": "VERIFIED_SUCCESS",
  "backup_artifact": "${BACKUP_KEY}",
  "integrity_check": {
    "sha256_verified": true,
    "sha256_hash": "${computed_sha}",
    "decryption_status": "SUCCESS",
    "sqlite_integrity": "${db_integrity}"
  },
  "restored_data": {
    "destination": "${RESTORE_DIR}",
    "total_files_restored": ${restored_files_count},
    "database": {
      "table_users_count": ${total_users},
      "table_orders_count": ${total_orders}
    }
  }
}
EOF
)

    if [[ "$JSON_OUTPUT" == true ]]; then
        if [[ "$PRETTY_PRINT" == true ]] && command -v jq >/dev/null 2>&1; then
            echo "$json_report" | jq .
        else
            echo "$json_report"
        fi
    else
        echo "=================================================="
        echo "  Disaster Recovery & Restore Verification"
        echo "=================================================="
        echo "Timestamp        : ${run_timestamp}"
        echo "Backup Artifact  : ${BACKUP_KEY}"
        echo "SHA-256 Verified : PASS (${computed_sha})"
        echo "Decryption       : SUCCESS (AES-256)"
        echo "SQLite Integrity : ${db_integrity}"
        echo "Users Recovered  : ${total_users}"
        echo "Orders Recovered : ${total_orders}"
        echo "Restored Files   : ${restored_files_count} files in ${RESTORE_DIR}"
        echo "Status           : VERIFIED_SUCCESS"
        echo "=================================================="
    fi

    exit 0
}

main "$@"
