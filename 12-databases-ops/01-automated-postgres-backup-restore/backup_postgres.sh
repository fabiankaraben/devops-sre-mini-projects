#!/usr/bin/env bash
# ==============================================================================
# backup_postgres.sh - Automated PostgreSQL Backup with SHA256 & Retention
# ==============================================================================
# Creates consistent, compressed database backups using pg_dump, generates
# cryptographic SHA-256 manifests, records metadata, and enforces retention.
# Supports both direct host execution and Docker container execution.
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

# Configuration with Environment Variable Fallbacks
DB_HOST="${POSTGRES_PRIMARY_HOST:-localhost}"
DB_PORT="${POSTGRES_PRIMARY_PORT:-5432}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASS="${POSTGRES_PASSWORD:-postgres}"
DB_NAME="${POSTGRES_DB:-production_db}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
KEEP_LAST_COUNT="${KEEP_LAST_COUNT:-5}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
FORMAT="plain_gzip" # Options: plain_gzip (.sql.gz) or custom (.dump)
CONTAINER_NAME="postgres-primary"
DRY_RUN=false
SILENT=false

# ------------------------------------------------------------------------------
# Help Menu
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: ./backup_postgres.sh [OPTIONS]

Production-grade automated PostgreSQL backup generator with compression,
SHA256 manifests, metadata generation, and retention pruning.

Options:
  --host <host>            PostgreSQL host (default: ${DB_HOST})
  --port <port>            PostgreSQL port (default: ${DB_PORT})
  --db <dbname>            Database name to dump (default: ${DB_NAME})
  --user <username>        Database user (default: ${DB_USER})
  --password <password>    Database password (default: ********)
  --out-dir <path>         Output directory for backups (default: ${BACKUP_DIR})
  --format <fmt>           Backup format: 'plain_gzip' or 'custom' (default: ${FORMAT})
  --retention-days <days>  Days to retain backup archives (default: ${RETENTION_DAYS})
  --keep-last <count>      Minimum number of recent backups to keep (default: ${KEEP_LAST_COUNT})
  --container <name>       Docker container name for fallback dump (default: ${CONTAINER_NAME})
  --dry-run                Simulate backup creation and retention without changes
  --silent                 Suppress banner and info logs
  --help, -h               Show this help message

Examples:
  ./backup_postgres.sh
  ./backup_postgres.sh --db production_db --out-dir ./backups --retention-days 14
  ./backup_postgres.sh --format custom --keep-last 10
EOF
}

# ------------------------------------------------------------------------------
# Parse CLI Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            DB_HOST="$2"; shift 2 ;;
        --port)
            DB_PORT="$2"; shift 2 ;;
        --db)
            DB_NAME="$2"; shift 2 ;;
        --user)
            DB_USER="$2"; shift 2 ;;
        --password)
            DB_PASS="$2"; shift 2 ;;
        --out-dir)
            BACKUP_DIR="$2"; shift 2 ;;
        --format)
            FORMAT="$2"; shift 2 ;;
        --retention-days)
            RETENTION_DAYS="$2"; shift 2 ;;
        --keep-last)
            KEEP_LAST_COUNT="$2"; shift 2 ;;
        --container)
            CONTAINER_NAME="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --silent)
            SILENT=true; shift ;;
        --help|-h)
            show_help; exit 0 ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help; exit 1 ;;
    esac
done

# Ensure backup directory is strictly inside project directory or absolute path
mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date -u +"%Y%m%d_%H%M%SZ")"
DATE_HUMAN="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

if [[ "$FORMAT" == "custom" ]]; then
    BACKUP_FILENAME="${DB_NAME}_${TIMESTAMP}.dump"
else
    BACKUP_FILENAME="${DB_NAME}_${TIMESTAMP}.sql.gz"
fi

FINAL_BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"
TEMP_BACKUP_PATH="$BACKUP_DIR/.tmp_${BACKUP_FILENAME}"
SHA256_PATH="$BACKUP_DIR/${BACKUP_FILENAME}.sha256"
META_PATH="$BACKUP_DIR/${BACKUP_FILENAME}.meta.json"

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
# Banner
# ------------------------------------------------------------------------------
if [ "$SILENT" = false ]; then
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  📦 Automated PostgreSQL Backup & Integrity Engine"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "  Target Database : ${CLR_BOLD}${DB_NAME}${CLR_RESET} on ${DB_HOST}:${DB_PORT}"
    echo -e "  Backup Format   : ${CLR_BOLD}${FORMAT}${CLR_RESET}"
    echo -e "  Destination     : ${BACKUP_DIR}/"
    echo -e "  Retention Policy: ${RETENTION_DAYS} days (keeping at least ${KEEP_LAST_COUNT} snapshots)"
    echo "----------------------------------------------------------------------"
fi

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would generate backup: $FINAL_BACKUP_PATH"
    log_info "[DRY-RUN] Skipping actual dump execution."
    exit 0
fi

# ------------------------------------------------------------------------------
# Check Tool Availability (Host pg_dump vs Docker Container)
# ------------------------------------------------------------------------------
USE_DOCKER=false
if command -v pg_dump >/dev/null 2>&1; then
    log_info "Using host 'pg_dump' utility."
else
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_info "Host 'pg_dump' not found. Using Docker container '${CONTAINER_NAME}'."
        USE_DOCKER=true
    else
        log_error "Neither local 'pg_dump' nor running Docker container '${CONTAINER_NAME}' is available."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 1. Capture Database Table Metadata & Row Counts Before Dump
# ------------------------------------------------------------------------------
log_info "Extracting table row counts and database metadata..."
TABLES_QUERY="SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;"

TABLES=()
if [ "$USE_DOCKER" = false ]; then
    export PGPASSWORD="$DB_PASS"
    if command -v psql >/dev/null 2>&1; then
        while IFS= read -r tbl; do
            [[ -n "$tbl" ]] && TABLES+=("$tbl")
        done < <(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$TABLES_QUERY" 2>/dev/null || true)
    fi
else
    while IFS= read -r tbl; do
        [[ -n "$tbl" ]] && TABLES+=("$tbl")
    done < <(docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$TABLES_QUERY" 2>/dev/null || true)
fi

TABLE_COUNTS_JSON="{"
FIRST=true
TOTAL_ROWS=0

for tbl in "${TABLES[@]}"; do
    COUNT_QUERY="SELECT COUNT(*) FROM \"$tbl\";"
    ROW_COUNT=0
    if [ "$USE_DOCKER" = false ]; then
        ROW_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$COUNT_QUERY" 2>/dev/null || echo "0")
    else
        ROW_COUNT=$(docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$COUNT_QUERY" 2>/dev/null || echo "0")
    fi
    ROW_COUNT="${ROW_COUNT//[$'\t\r\n ']/}"
    if [[ -n "$ROW_COUNT" && "$ROW_COUNT" =~ ^[0-9]+$ ]]; then
        TOTAL_ROWS=$((TOTAL_ROWS + ROW_COUNT))
        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            TABLE_COUNTS_JSON+=","
        fi
        TABLE_COUNTS_JSON+="\"$tbl\": $ROW_COUNT"
    fi
done
TABLE_COUNTS_JSON+="}"

# ------------------------------------------------------------------------------
# 2. Execute Atomic pg_dump
# ------------------------------------------------------------------------------
log_info "Initiating atomic database snapshot with pg_dump..."
START_TIME=$(date +%s)

if [ "$USE_DOCKER" = false ]; then
    export PGPASSWORD="$DB_PASS"
    if [[ "$FORMAT" == "custom" ]]; then
        pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -F c -b -v --no-owner --no-privileges > "$TEMP_BACKUP_PATH" 2>/dev/null
    else
        pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            --clean --if-exists --no-owner --no-privileges \
            | gzip -"${COMPRESSION_LEVEL}" -c > "$TEMP_BACKUP_PATH"
    fi
else
    if [[ "$FORMAT" == "custom" ]]; then
        docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" \
            pg_dump -U "$DB_USER" -d "$DB_NAME" -F c -b --no-owner --no-privileges > "$TEMP_BACKUP_PATH"
    else
        docker exec -e PGPASSWORD="$DB_PASS" "$CONTAINER_NAME" \
            pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner --no-privileges \
            | gzip -"${COMPRESSION_LEVEL}" -c > "$TEMP_BACKUP_PATH"
    fi
fi

# Verify dump output
if [[ ! -s "$TEMP_BACKUP_PATH" ]]; then
    log_error "pg_dump produced an empty or non-existent file: $TEMP_BACKUP_PATH"
    rm -f "$TEMP_BACKUP_PATH"
    exit 1
fi

mv "$TEMP_BACKUP_PATH" "$FINAL_BACKUP_PATH"
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# ------------------------------------------------------------------------------
# 3. Compute Cryptographic SHA-256 Checksum Manifest
# ------------------------------------------------------------------------------
log_info "Computing SHA-256 cryptographic manifest..."
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$BACKUP_DIR" && sha256sum "$BACKUP_FILENAME" > "${BACKUP_FILENAME}.sha256")
elif command -v shasum >/dev/null 2>&1; then
    (cd "$BACKUP_DIR" && shasum -a 256 "$BACKUP_FILENAME" > "${BACKUP_FILENAME}.sha256")
else
    # Fallback to python
    python3 -c "
import hashlib, os
with open('$FINAL_BACKUP_PATH', 'rb') as f:
    h = hashlib.sha256(f.read()).hexdigest()
with open('$SHA256_PATH', 'w') as out:
    out.write(f'{h}  $BACKUP_FILENAME\n')
"
fi

SHA256_HASH=$(awk '{print $1}' "$SHA256_PATH")
FILE_SIZE_BYTES=$(wc -c < "$FINAL_BACKUP_PATH" | tr -d ' ')
FILE_SIZE_HUMAN=$(du -h "$FINAL_BACKUP_PATH" | awk '{print $1}')

# ------------------------------------------------------------------------------
# 4. Generate Metadata Manifest JSON
# ------------------------------------------------------------------------------
cat <<EOF > "$META_PATH"
{
  "backup_file": "$BACKUP_FILENAME",
  "database": "$DB_NAME",
  "created_at": "$DATE_HUMAN",
  "timestamp_utc": "$TIMESTAMP",
  "format": "$FORMAT",
  "sha256": "$SHA256_HASH",
  "size_bytes": $FILE_SIZE_BYTES,
  "size_human": "$FILE_SIZE_HUMAN",
  "duration_seconds": $DURATION,
  "total_rows": $TOTAL_ROWS,
  "tables": $TABLE_COUNTS_JSON
}
EOF

log_success "Backup artifact created: $FINAL_BACKUP_PATH ($FILE_SIZE_HUMAN)"
log_success "SHA-256 Checksum: $SHA256_HASH"
log_success "Metadata Manifest: $META_PATH"

# ------------------------------------------------------------------------------
# 5. Enforce Retention Policy & Prune Stale Snapshots
# ------------------------------------------------------------------------------
log_info "Evaluating retention policy (${RETENTION_DAYS} days, min ${KEEP_LAST_COUNT} copies)..."

# Collect all matching backups sorted oldest first
ALL_BACKUPS=()
while IFS= read -r f; do
    [[ -n "$f" ]] && ALL_BACKUPS+=("$f")
done < <(find "$BACKUP_DIR" -maxdepth 1 \( -name "${DB_NAME}_*.sql.gz" -o -name "${DB_NAME}_*.dump" \) -type f | sort)

TOTAL_BACKUPS=${#ALL_BACKUPS[@]}
DELETED_COUNT=0

if (( TOTAL_BACKUPS > KEEP_LAST_COUNT )); then
    PRUNABLE_CANDIDATES=$((TOTAL_BACKUPS - KEEP_LAST_COUNT))
    NOW_EPOCH=$(date +%s)
    RETENTION_SECONDS=$((RETENTION_DAYS * 86400))

    for (( i=0; i<PRUNABLE_CANDIDATES; i++ )); do
        CANDIDATE="${ALL_BACKUPS[$i]}"
        
        # Get file modification time in seconds
        if [[ "$OSTYPE" == "darwin"* ]]; then
            FILE_MTIME=$(stat -f "%m" "$CANDIDATE")
        else
            FILE_MTIME=$(stat -c "%Y" "$CANDIDATE")
        fi

        AGE_SECONDS=$((NOW_EPOCH - FILE_MTIME))
        if (( AGE_SECONDS > RETENTION_SECONDS )); then
            BASENAME_CANDIDATE="$(basename "$CANDIDATE")"
            log_info "Pruning expired backup: $BASENAME_CANDIDATE (age: $((AGE_SECONDS / 86400)) days)"
            rm -f "$CANDIDATE"
            rm -f "$BACKUP_DIR/${BASENAME_CANDIDATE}.sha256"
            rm -f "$BACKUP_DIR/${BASENAME_CANDIDATE}.meta.json"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        fi
    done
fi

if (( DELETED_COUNT > 0 )); then
    log_success "Retention pruning completed. Removed $DELETED_COUNT expired backup archive(s)."
else
    log_info "No backup archives eligible for retention pruning (Total current: $TOTAL_BACKUPS)."
fi

# Print final result
if [ "$SILENT" = false ]; then
    echo "----------------------------------------------------------------------"
    echo -e "${CLR_GREEN}${CLR_BOLD}🎉 Automated Backup Completed Successfully!${CLR_RESET}"
    echo -e "  Archive File : ${FINAL_BACKUP_PATH}"
    echo -e "  SHA256 File  : ${SHA256_PATH}"
    echo -e "  Metadata File: ${META_PATH}"
    echo "======================================================================"
fi

exit 0
