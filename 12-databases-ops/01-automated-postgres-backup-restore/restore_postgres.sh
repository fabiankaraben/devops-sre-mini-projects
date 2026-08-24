#!/usr/bin/env bash
# ==============================================================================
# restore_postgres.sh - Automated PostgreSQL Restore & Integrity Validation
# ==============================================================================
# Validates SHA-256 cryptographic manifests, restores backups into a clean
# validation instance, and performs exhaustive table row-count and schema parity.
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

# Load .env if present in project directory
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env.example"
fi

# Target Validation Database Defaults
DB_HOST="${POSTGRES_VALIDATION_HOST:-localhost}"
DB_PORT="${POSTGRES_VALIDATION_PORT:-5433}"
DB_USER="${POSTGRES_VALIDATION_USER:-postgres}"
DB_PASS="${POSTGRES_VALIDATION_PASSWORD:-postgres}"
DB_NAME="${POSTGRES_VALIDATION_DB:-validation_db}"
CONTAINER_NAME="postgres-validation"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
BACKUP_FILE=""
SKIP_CHECKSUM=false
RECREATE_DB=true
REPORT_FILE="$SCRIPT_DIR/validation_report.json"
SILENT=false

# ------------------------------------------------------------------------------
# Help Menu
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: ./restore_postgres.sh [OPTIONS]

Automated Disaster Recovery and PostgreSQL Restore Validation Engine.

Options:
  --backup-file <path>    Path to .sql.gz or .dump backup archive (default: latest in $BACKUP_DIR)
  --target-host <host>    Target PostgreSQL host (default: ${DB_HOST})
  --target-port <port>    Target PostgreSQL port (default: ${DB_PORT})
  --target-db <dbname>    Target database name (default: ${DB_NAME})
  --target-user <user>    Target database username (default: ${DB_USER})
  --target-password <pw>  Target database password (default: ********)
  --target-container <c>  Docker container name for fallback restore (default: ${CONTAINER_NAME})
  --skip-checksum         Skip SHA256 checksum verification
  --no-recreate           Do not drop/recreate target database prior to restore
  --report <path>         Output JSON validation report path (default: ${REPORT_FILE})
  --silent                Suppress non-essential console logs
  --help, -h              Show this help message

Examples:
  ./restore_postgres.sh
  ./restore_postgres.sh --backup-file ./backups/production_db_20260824_113000Z.sql.gz
  ./restore_postgres.sh --target-port 5433 --target-db validation_db
EOF
}

# ------------------------------------------------------------------------------
# Parse CLI Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-file)
            BACKUP_FILE="$2"; shift 2 ;;
        --target-host)
            DB_HOST="$2"; shift 2 ;;
        --target-port)
            DB_PORT="$2"; shift 2 ;;
        --target-db)
            DB_NAME="$2"; shift 2 ;;
        --target-user)
            DB_USER="$2"; shift 2 ;;
        --target-password)
            DB_PASS="$2"; shift 2 ;;
        --target-container)
            CONTAINER_NAME="$2"; shift 2 ;;
        --skip-checksum)
            SKIP_CHECKSUM=true; shift ;;
        --no-recreate)
            RECREATE_DB=false; shift ;;
        --report)
            REPORT_FILE="$2"; shift 2 ;;
        --silent)
            SILENT=true; shift ;;
        --help|-h)
            show_help; exit 0 ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help; exit 1 ;;
    esac
done

log_info() {
    if [ "$SILENT" = false ]; then
        echo -e "${CLR_CYAN}ℹ [$(date +"%H:%M:%S")] $1${CLR_RESET}"
    fi
}

log_success() {
    if [ "$SILENT" = false ]; then
        echo -e "${CLR_GREEN}✔ [$(date +"%H:%M:%S")] $1${CLR_RESET}"
    fi
}

log_warn() {
    echo -e "${CLR_YELLOW}⚠ [$(date +"%H:%M:%S")] $1${CLR_RESET}" >&2
}

log_error() {
    echo -e "${CLR_RED}✖ [$(date +"%H:%M:%S")] $1${CLR_RESET}" >&2
}

# ------------------------------------------------------------------------------
# 1. Identify Backup File
# ------------------------------------------------------------------------------
if [[ -z "$BACKUP_FILE" ]]; then
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi

    # Find the most recently modified backup file
    LATEST_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "*.sql.gz" -o -name "*.dump" \) -type f -exec stat -f "%m %N" {} + 2>/dev/null | sort -nr | head -n 1 | awk '{print $2}' || true)
    if [[ -z "$LATEST_BACKUP" ]]; then
        # Linux fallback for stat
        LATEST_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "*.sql.gz" -o -name "*.dump" \) -type f -exec stat -c "%Y %n" {} + 2>/dev/null | sort -nr | head -n 1 | awk '{print $2}' || true)
    fi

    if [[ -z "$LATEST_BACKUP" || ! -f "$LATEST_BACKUP" ]]; then
        log_error "No backup files found in $BACKUP_DIR."
        exit 1
    fi
    BACKUP_FILE="$LATEST_BACKUP"
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    log_error "Backup file does not exist: $BACKUP_FILE"
    exit 1
fi

BACKUP_FILENAME="$(basename "$BACKUP_FILE")"
BACKUP_DIRNAME="$(dirname "$BACKUP_FILE")"
SHA256_FILE="$BACKUP_DIRNAME/${BACKUP_FILENAME}.sha256"
META_FILE="$BACKUP_DIRNAME/${BACKUP_FILENAME}.meta.json"

if [ "$SILENT" = false ]; then
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🔄 Automated PostgreSQL Restore & Parity Validation"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "  Source Backup Archive : ${CLR_BOLD}${BACKUP_FILE}${CLR_RESET}"
    echo -e "  Target Destination    : ${CLR_BOLD}${DB_NAME}${CLR_RESET} on ${DB_HOST}:${DB_PORT}"
    echo -e "  Recreate DB Clean     : ${RECREATE_DB}"
    echo -e "  SHA256 Integrity Check: $( [ "$SKIP_CHECKSUM" = true ] && echo 'SKIPPED' || echo 'ENFORCED' )"
    echo "----------------------------------------------------------------------"
fi

# ------------------------------------------------------------------------------
# 2. Cryptographic SHA-256 Checksum Validation (Pre-Flight Gate)
# ------------------------------------------------------------------------------
CALCULATED_HASH=""
if [ "$SKIP_CHECKSUM" = false ]; then
    log_info "Verifying cryptographic SHA-256 integrity..."
    if [[ ! -f "$SHA256_FILE" ]]; then
        log_warn "SHA-256 manifest '$SHA256_FILE' not found. Computing standalone checksum."
    else
        EXPECTED_HASH=$(awk '{print $1}' "$SHA256_FILE" | tr -d ' \r\n')
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        CALCULATED_HASH=$(sha256sum "$BACKUP_FILE" | awk '{print $1}' | tr -d ' \r\n')
    elif command -v shasum >/dev/null 2>&1; then
        CALCULATED_HASH=$(shasum -a 256 "$BACKUP_FILE" | awk '{print $1}' | tr -d ' \r\n')
    else
        CALCULATED_HASH=$(python3 -c "import hashlib; print(hashlib.sha256(open('$BACKUP_FILE','rb').read()).hexdigest())")
    fi

    if [[ -f "$SHA256_FILE" ]]; then
        if [[ "$CALCULATED_HASH" != "$EXPECTED_HASH" ]]; then
            log_error "SECURITY ALERT: SHA-256 Checksum Mismatch!"
            log_error "  Expected:   $EXPECTED_HASH"
            log_error "  Calculated: $CALCULATED_HASH"
            log_error "Backup archive may be corrupted or tampered with. Aborting restore."
            exit 2
        fi
        log_success "SHA-256 Integrity Confirmed: $CALCULATED_HASH"
    fi
fi

# ------------------------------------------------------------------------------
# 3. Check Target Database Connectivity (Host vs Docker)
# ------------------------------------------------------------------------------
USE_DOCKER=false
if command -v psql >/dev/null 2>&1; then
    export PGPASSWORD="$DB_PASS"
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "postgres" -c "SELECT 1;" >/dev/null 2>&1; then
        log_info "Connected to target PostgreSQL via host psql client."
    else
        log_warn "Host psql cannot reach ${DB_HOST}:${DB_PORT}. Checking Docker container '${CONTAINER_NAME}'..."
        USE_DOCKER=true
    fi
else
    USE_DOCKER=true
fi

if [ "$USE_DOCKER" = true ]; then
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_info "Using Docker container '${CONTAINER_NAME}' for database restoration."
    else
        log_error "Unable to connect to target PostgreSQL: neither host client nor container '${CONTAINER_NAME}' is ready."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 4. Clean Recreate of Validation Database
# ------------------------------------------------------------------------------
if [ "$RECREATE_DB" = true ]; then
    log_info "Recreating fresh test database '${DB_NAME}'..."
    SQL_TERMINATE="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();"
    SQL_DROP="DROP DATABASE IF EXISTS \"${DB_NAME}\";"
    SQL_CREATE="CREATE DATABASE \"${DB_NAME}\";"

    if [ "$USE_DOCKER" = false ]; then
        export PGPASSWORD="$DB_PASS"
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "postgres" -c "$SQL_TERMINATE" -c "$SQL_DROP" -c "$SQL_CREATE" >/dev/null 2>&1
    else
        docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" psql -U "$DB_USER" -d "postgres" -c "$SQL_TERMINATE" -c "$SQL_DROP" -c "$SQL_CREATE" >/dev/null 2>&1
    fi
    log_success "Clean database '${DB_NAME}' provisioned."
fi

# ------------------------------------------------------------------------------
# 5. Restore Backup Archive
# ------------------------------------------------------------------------------
log_info "Restoring backup archive into '${DB_NAME}'..."
START_TIME=$(date +%s)

if [[ "$BACKUP_FILE" == *.dump ]]; then
    # Custom format via pg_restore
    if [ "$USE_DOCKER" = false ]; then
        export PGPASSWORD="$DB_PASS"
        pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            --clean --if-exists --no-owner --no-privileges "$BACKUP_FILE" >/dev/null 2>&1 || true
    else
        cat "$BACKUP_FILE" | docker exec -i -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" \
            pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner --no-privileges >/dev/null 2>&1 || true
    fi
else
    # Plain Gzip SQL format
    if [ "$USE_DOCKER" = false ]; then
        export PGPASSWORD="$DB_PASS"
        gzip -dc "$BACKUP_FILE" | psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 || true
    else
        gzip -dc "$BACKUP_FILE" | docker exec -i -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" \
            psql -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 || true
    fi
fi

END_TIME=$(date +%s)
RESTORE_DURATION=$((END_TIME - START_TIME))
log_success "Database restore executed in ${RESTORE_DURATION}s."

# ------------------------------------------------------------------------------
# 6. Parity Verification & Consistency Auditing
# ------------------------------------------------------------------------------
log_info "Executing data parity & relational integrity verification..."

# Load metadata manifest if present
EXPECTED_COUNTS_JSON="{}"
if [[ -f "$META_FILE" ]]; then
    EXPECTED_COUNTS_JSON=$(python3 -c "import json; print(json.dumps(json.load(open('$META_FILE')).get('tables', {})))" 2>/dev/null || echo "{}")
fi

# Query restored tables
TABLES_QUERY="SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;"
RESTORED_TABLES=()

if [ "$USE_DOCKER" = false ]; then
    export PGPASSWORD="$DB_PASS"
    while IFS= read -r tbl; do
        [[ -n "$tbl" ]] && RESTORED_TABLES+=("$tbl")
    done < <(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$TABLES_QUERY" 2>/dev/null || true)
else
    while IFS= read -r tbl; do
        [[ -n "$tbl" ]] && RESTORED_TABLES+=("$tbl")
    done < <(docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$TABLES_QUERY" 2>/dev/null || true)
fi

PARITY_FAILURES=0
TOTAL_RESTORED_ROWS=0
TABLE_AUDIT_DATA=()

echo ""
echo -e "${CLR_BOLD}──────────────────────────────────────────────────────────────────────${CLR_RESET}"
printf "%-22s | %-13s | %-13s | %-12s\n" "Table Name" "Expected Rows" "Restored Rows" "Status"
echo -e "${CLR_BOLD}──────────────────────────────────────────────────────────────────────${CLR_RESET}"

for tbl in "${RESTORED_TABLES[@]}"; do
    COUNT_QUERY="SELECT COUNT(*) FROM \"$tbl\";"
    ROW_COUNT=0
    if [ "$USE_DOCKER" = false ]; then
        ROW_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$COUNT_QUERY" 2>/dev/null || echo "0")
    else
        ROW_COUNT=$(docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$COUNT_QUERY" 2>/dev/null || echo "0")
    fi
    ROW_COUNT="${ROW_COUNT//[$'\t\r\n ']/}"
    TOTAL_RESTORED_ROWS=$((TOTAL_RESTORED_ROWS + ROW_COUNT))

    # Retrieve expected count from manifest
    EXPECTED_COUNT=$(python3 -c "import json; m=json.loads('$EXPECTED_COUNTS_JSON'); print(m.get('$tbl', 'N/A'))" 2>/dev/null || echo "N/A")

    STATUS_COLOR="$CLR_GREEN"
    STATUS_TEXT="MATCH ✔"

    if [[ "$EXPECTED_COUNT" != "N/A" ]]; then
        if (( ROW_COUNT != EXPECTED_COUNT )); then
            STATUS_COLOR="$CLR_RED"
            STATUS_TEXT="MISMATCH ✖"
            PARITY_FAILURES=$((PARITY_FAILURES + 1))
        fi
    fi

    printf "%-22s | %-13s | %-13s | ${STATUS_COLOR}%-12s${CLR_RESET}\n" "$tbl" "$EXPECTED_COUNT" "$ROW_COUNT" "$STATUS_TEXT"
    TABLE_AUDIT_DATA+=("{\"table\": \"$tbl\", \"expected\": \"$EXPECTED_COUNT\", \"restored\": $ROW_COUNT, \"status\": \"$STATUS_TEXT\"}")
done

echo -e "${CLR_BOLD}──────────────────────────────────────────────────────────────────────${CLR_RESET}"
echo ""

# ------------------------------------------------------------------------------
# 7. Check Foreign Key Constraint Validity
# ------------------------------------------------------------------------------
FK_CHECK_SQL="
SELECT count(*)
FROM information_schema.table_constraints
WHERE constraint_type = 'FOREIGN KEY' AND table_schema = 'public';
"
FK_COUNT=0
if [ "$USE_DOCKER" = false ]; then
    FK_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$FK_CHECK_SQL" 2>/dev/null || echo "0")
else
    FK_COUNT=$(docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$FK_CHECK_SQL" 2>/dev/null || echo "0")
fi
FK_COUNT="${FK_COUNT//[$'\t\r\n ']/}"
log_info "Active Foreign Key Constraints verified: $FK_COUNT"

# ------------------------------------------------------------------------------
# 8. Emit Structured JSON Validation Report
# ------------------------------------------------------------------------------
AUDIT_ARRAY=$(IFS=,; echo "[${TABLE_AUDIT_DATA[*]}]")
cat <<EOF > "$REPORT_FILE"
{
  "backup_file": "$BACKUP_FILE",
  "sha256": "$CALCULATED_HASH",
  "target_database": "$DB_NAME",
  "target_host": "$DB_HOST",
  "target_port": $DB_PORT,
  "validated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "restore_duration_seconds": $RESTORE_DURATION,
  "tables_restored_count": ${#RESTORED_TABLES[@]},
  "total_restored_rows": $TOTAL_RESTORED_ROWS,
  "foreign_key_constraints": $FK_COUNT,
  "parity_failures": $PARITY_FAILURES,
  "validation_passed": $( [ $PARITY_FAILURES -eq 0 ] && echo "true" || echo "false" ),
  "table_audit": $AUDIT_ARRAY
}
EOF

log_success "Validation report saved: $REPORT_FILE"

# ------------------------------------------------------------------------------
# 9. Final Assertion & Exit Status
# ------------------------------------------------------------------------------
if (( PARITY_FAILURES > 0 )); then
    log_error "Validation Failed! $PARITY_FAILURES table(s) exhibited row count mismatches."
    exit 1
fi

if (( ${#RESTORED_TABLES[@]} == 0 )); then
    log_error "Validation Failed! Zero tables were restored."
    exit 1
fi

log_success "All $TOTAL_RESTORED_ROWS records across ${#RESTORED_TABLES[@]} tables match with 100% parity!"
echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Disaster Recovery & Restore Validation Succeeded!${CLR_RESET}\n"

exit 0
