#!/usr/bin/env bash
# ==============================================================================
# Script Name: backup_s3.sh
# Description: Production-grade Automated Backup & S3 Encryption Pipeline.
#              Generates atomic SQLite database dumps, bundles filesystem assets,
#              applies symmetric AES-256 encryption (GPG / OpenSSL), computes
#              cryptographic SHA-256 checksums, and uploads to S3/MinIO/mock storage.
#
# Exit Codes:
#   0 - Success: Backup generated, encrypted, and uploaded successfully.
#   1 - Partial Failure: Non-critical warning.
#   2 - Fatal Error: Missing source database, encryption error, or upload failure.
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults (scoped inside project directory)
DB_PATH="${SCRIPT_DIR}/data/app_production.db"
DATA_DIR="${SCRIPT_DIR}/data/uploads"
S3_BUCKET="production-backups"
S3_ENDPOINT=""
MOCK_S3_DIR="${SCRIPT_DIR}/mock_s3_bucket"
GPG_PASSPHRASE="DevOpsSecretPassphrase2026!"
BACKUP_PREFIX="backup"
STAGING_DIR="/tmp/backup_staging_$$"
JSON_OUTPUT=false
PRETTY_PRINT=false

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automated Backup with S3 Upload (DevOps / SRE Mini-Project)
Creates atomic database dumps, encrypts with AES-256 (GPG/OpenSSL), and uploads to S3/MinIO.

Options:
  --db-path <path>          Path to SQLite database to back up (default: ./data/app_production.db)
  --data-dir <path>         Directory of filesystem assets to include (default: ./data/uploads)
  --s3-bucket <bucket>      Target S3 bucket name (default: production-backups)
  --s3-endpoint <url>       Optional MinIO/LocalStack S3 endpoint URL (e.g. http://localhost:9000)
  --mock-s3-dir <path>      Local folder acting as mock S3 bucket (default: ./mock_s3_bucket)
  --passphrase <string>     Symmetric encryption passphrase (default: DevOpsSecretPassphrase2026!)
  --passphrase-file <path>  File containing passphrase
  --backup-prefix <name>    Filename prefix for backup archive (default: backup)
  --json                    Emit structured execution report in JSON format
  --pretty                  Format JSON report with 2-space indentation
  -h, --help                Display this help message and exit
  -v, --version             Display version information and exit

Examples:
  # Backup with local mock S3 storage and JSON output
  $(basename "$0") --json --pretty

  # Backup to MinIO local instance
  $(basename "$0") --s3-endpoint http://localhost:9000 --s3-bucket app-backups
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

# Portable SHA256 calculation
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

# Portable file size in bytes
get_file_size() {
    local target_file="$1"
    if stat -c %s "$target_file" >/dev/null 2>&1; then
        stat -c %s "$target_file"
    elif stat -f %z "$target_file" >/dev/null 2>&1; then
        stat -f %z "$target_file"
    else
        wc -c < "$target_file" | tr -d ' '
    fi
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --db-path)
                [[ $# -lt 2 ]] && { print_error "Missing value for --db-path"; exit 2; }
                DB_PATH="$2"
                shift 2
                ;;
            --data-dir)
                [[ $# -lt 2 ]] && { print_error "Missing value for --data-dir"; exit 2; }
                DATA_DIR="$2"
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
            --mock-s3-dir)
                [[ $# -lt 2 ]] && { print_error "Missing value for --mock-s3-dir"; exit 2; }
                MOCK_S3_DIR="$2"
                shift 2
                ;;
            --passphrase)
                [[ $# -lt 2 ]] && { print_error "Missing value for --passphrase"; exit 2; }
                GPG_PASSPHRASE="$2"
                shift 2
                ;;
            --passphrase-file)
                [[ $# -lt 2 ]] && { print_error "Missing value for --passphrase-file"; exit 2; }
                if [[ ! -f "$2" ]]; then print_error "Passphrase file '$2' not found"; exit 2; fi
                GPG_PASSPHRASE=$(cat "$2")
                shift 2
                ;;
            --backup-prefix)
                [[ $# -lt 2 ]] && { print_error "Missing value for --backup-prefix"; exit 2; }
                BACKUP_PREFIX="$2"
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
                echo "backup_s3.sh version ${VERSION}"
                exit 0
                ;;
            *)
                print_error "Unrecognized option: '$1'. Run with --help for usage."
                exit 2
                ;;
        esac
    done

    if [[ ! -f "$DB_PATH" ]]; then
        print_error "Source database '${DB_PATH}' does not exist"
        exit 2
    fi
}

# ------------------------------------------------------------------------------
# Backup Pipeline Execution
# ------------------------------------------------------------------------------

main() {
    parse_args "$@"

    local run_timestamp iso_stamp
    run_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    iso_stamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")

    local backup_base_name="${BACKUP_PREFIX}_${iso_stamp}"
    local content_stage="${STAGING_DIR}/contents"
    mkdir -p "$content_stage"

    # --------------------------------------------------------------------------
    # Step 1: Atomic SQLite Database Snapshot
    # --------------------------------------------------------------------------
    local db_dump_file="${content_stage}/database.sqlite"
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$DB_PATH" ".backup '${db_dump_file}'"
    else
        cp -p "$DB_PATH" "$db_dump_file"
    fi

    # --------------------------------------------------------------------------
    # Step 2: Bundle Filesystem Assets
    # --------------------------------------------------------------------------
    if [[ -d "$DATA_DIR" ]]; then
        mkdir -p "${content_stage}/uploads"
        cp -r "$DATA_DIR"/* "${content_stage}/uploads/" 2>/dev/null || true
    fi

    # --------------------------------------------------------------------------
    # Step 3: Bundle and Compress into Tarball (.tar.gz)
    # --------------------------------------------------------------------------
    local raw_tar_gz="${STAGING_DIR}/${backup_base_name}.tar.gz"
    tar -czf "$raw_tar_gz" -C "$content_stage" .

    local raw_size pre_enc_sha256
    raw_size=$(get_file_size "$raw_tar_gz")
    pre_enc_sha256=$(calculate_sha256 "$raw_tar_gz")

    # --------------------------------------------------------------------------
    # Step 4: Symmetric Encryption (GPG AES-256 / OpenSSL AES-256-CBC)
    # --------------------------------------------------------------------------
    local encrypted_archive="${STAGING_DIR}/${backup_base_name}.tar.gz.enc"
    local encryption_tool="OpenSSL"

    if command -v gpg >/dev/null 2>&1; then
        encryption_tool="GPG (AES-256)"
        gpg --batch --yes --passphrase "$GPG_PASSPHRASE" \
            --symmetric --cipher-algo AES256 \
            -o "$encrypted_archive" "$raw_tar_gz" 2>/dev/null
    elif command -v openssl >/dev/null 2>&1; then
        encryption_tool="OpenSSL (AES-256-CBC-PBKDF2)"
        openssl enc -aes-256-cbc -pbkdf2 -salt -pass "pass:$GPG_PASSPHRASE" \
            -in "$raw_tar_gz" -out "$encrypted_archive" 2>/dev/null
    else
        print_error "Neither 'gpg' nor 'openssl' found in PATH for encryption."
        exit 2
    fi

    local enc_size post_enc_sha256
    enc_size=$(get_file_size "$encrypted_archive")
    post_enc_sha256=$(calculate_sha256 "$encrypted_archive")

    # Write SHA256 manifest file
    local sha256_manifest_file="${STAGING_DIR}/${backup_base_name}.tar.gz.enc.sha256"
    echo "${post_enc_sha256}  ${backup_base_name}.tar.gz.enc" > "$sha256_manifest_file"

    # --------------------------------------------------------------------------
    # Step 5: Upload to Object Storage (S3 / MinIO / Mock Storage)
    # --------------------------------------------------------------------------
    local upload_destination=""
    local s3_key="${backup_base_name}.tar.gz.enc"
    local s3_sha_key="${backup_base_name}.tar.gz.enc.sha256"

    if [[ -n "$S3_ENDPOINT" ]] && command -v aws >/dev/null 2>&1; then
        aws s3 cp "$encrypted_archive" "s3://${S3_BUCKET}/${s3_key}" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
        aws s3 cp "$sha256_manifest_file" "s3://${S3_BUCKET}/${s3_sha_key}" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
        upload_destination="s3://${S3_BUCKET}/${s3_key} (endpoint: ${S3_ENDPOINT})"
    elif command -v aws >/dev/null 2>&1 && [[ "$MOCK_S3_DIR" == "none" ]]; then
        aws s3 cp "$encrypted_archive" "s3://${S3_BUCKET}/${s3_key}" >/dev/null 2>&1
        aws s3 cp "$sha256_manifest_file" "s3://${S3_BUCKET}/${s3_sha_key}" >/dev/null 2>&1
        upload_destination="s3://${S3_BUCKET}/${s3_key}"
    else
        mkdir -p "$MOCK_S3_DIR"
        cp "$encrypted_archive" "${MOCK_S3_DIR}/${s3_key}"
        cp "$sha256_manifest_file" "${MOCK_S3_DIR}/${s3_sha_key}"
        upload_destination="mock://${MOCK_S3_DIR}/${s3_key}"
    fi

    # --------------------------------------------------------------------------
    # Output Execution Report
    # --------------------------------------------------------------------------
    local json_report
    json_report=$(cat <<EOF
{
  "timestamp": "${run_timestamp}",
  "status": "SUCCESS",
  "backup_name": "${backup_base_name}",
  "source_db": "${DB_PATH}",
  "source_data_dir": "${DATA_DIR}",
  "encryption": {
    "tool": "${encryption_tool}",
    "cipher": "AES-256"
  },
  "artifacts": {
    "encrypted_archive": "${s3_key}",
    "sha256_manifest": "${s3_sha_key}",
    "raw_size_bytes": ${raw_size},
    "encrypted_size_bytes": ${enc_size},
    "pre_encryption_sha256": "${pre_enc_sha256}",
    "post_encryption_sha256": "${post_enc_sha256}"
  },
  "destination": "${upload_destination}"
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
        echo "  Automated Backup Pipeline - Execution Summary"
        echo "=================================================="
        echo "Timestamp        : ${run_timestamp}"
        echo "Backup Name      : ${backup_base_name}"
        echo "Encryption Tool  : ${encryption_tool}"
        echo "Raw Archive Size : ${raw_size} bytes"
        echo "Encrypted Size   : ${enc_size} bytes (AES-256)"
        echo "SHA-256 Checksum : ${post_enc_sha256}"
        echo "Destination      : ${upload_destination}"
        echo "Status           : SUCCESS"
        echo "=================================================="
    fi

    exit 0
}

main "$@"
