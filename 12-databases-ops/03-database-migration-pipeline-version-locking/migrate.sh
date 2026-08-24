#!/usr/bin/env bash
# ==============================================================================
# migrate.sh - Automated PostgreSQL Migration Runner with Version Locking
# ==============================================================================
# Wraps golang-migrate to provide transactional forward (up) and rollback (down)
# schema migrations, advisory locking, dirty-state recovery, and schema inspection.
# Supports both host binary and containerized runner (migrate/migrate:v4.17.0).
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

# Load .env if present
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env.example"
fi

DB_HOST="${POSTGRES_HOST:-localhost}"
DB_PORT="${POSTGRES_PORT:-5432}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASS="${POSTGRES_PASSWORD:-postgres}"
DB_NAME="${POSTGRES_DB:-migration_test_db}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$SCRIPT_DIR/migrations}"

HOST_DB_URL="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
DOCKER_DB_URL="postgres://${DB_USER}:${DB_PASS}@postgres-migration-db:5432/${DB_NAME}?sslmode=disable"

show_help() {
    cat <<EOF
Usage: ./migrate.sh <COMMAND> [ARGS...]

PostgreSQL Schema Migration Runner with Version Locking (golang-migrate).

Commands:
  up [N]             Apply all pending migrations, or optionally next N steps
  down [N]           Rollback all migrations, or optionally previous N steps
  goto <V>           Migrate directly to specific schema version V
  version            Print current schema version and dirty flag
  force <V>          Set schema version to V and clear dirty state (recovery)
  status             Show comparison of migration files vs applied version
  create <name>      Scaffold a new pair of timestamped .up.sql and .down.sql files
  help, -h           Show this help message

Examples:
  ./migrate.sh up
  ./migrate.sh up 1
  ./migrate.sh down 1
  ./migrate.sh goto 2
  ./migrate.sh version
  ./migrate.sh force 3
  ./migrate.sh create add_customer_indexes
EOF
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

COMMAND="$1"
shift

# ------------------------------------------------------------------------------
# Sync Local Migration Files into Docker Volume
# ------------------------------------------------------------------------------
sync_migration_files() {
    if docker ps --format '{{.Names}}' | grep -q "^postgres-migration-db$"; then
        docker exec postgres-migration-db rm -rf /migrations_data/* 2>/dev/null || true
        docker cp "$MIGRATIONS_DIR/." postgres-migration-db:/migrations_data/ >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------------------
# Check Tool Availability: Host 'migrate' vs Docker 'migrate/migrate'
# ------------------------------------------------------------------------------
run_migrate() {
    if command -v migrate >/dev/null 2>&1; then
        migrate -path "$MIGRATIONS_DIR" -database "$HOST_DB_URL" "$@"
    elif command -v docker >/dev/null 2>&1; then
        sync_migration_files
        docker run --rm \
            --network postgres-migration-net \
            -v postgres_migration_files:/migrations:ro \
            migrate/migrate:v4.17.0 \
            -path=/migrations \
            -database "$DOCKER_DB_URL" \
            "$@"
    else
        echo -e "${CLR_RED}Error: Neither local 'migrate' binary nor Docker is available.${CLR_RESET}" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Command Routing
# ------------------------------------------------------------------------------
case "$COMMAND" in
    up)
        echo -e "${CLR_CYAN}▶ Applying migrations (UP)...${CLR_RESET}"
        if [[ $# -gt 0 ]]; then
            run_migrate up "$1"
        else
            run_migrate up
        fi
        echo -e "${CLR_GREEN}✔ Migrations applied successfully.${CLR_RESET}"
        ;;

    down)
        STEPS="${1:-}"
        if [[ -z "$STEPS" ]]; then
            echo -e "${CLR_YELLOW}⚠ Warning: Executing full rollback of ALL migrations!${CLR_RESET}"
            run_migrate down -all
        else
            echo -e "${CLR_CYAN}▶ Rolling back $STEPS migration(s) (DOWN)...${CLR_RESET}"
            run_migrate down "$STEPS"
        fi
        echo -e "${CLR_GREEN}✔ Rollback completed successfully.${CLR_RESET}"
        ;;

    goto)
        if [[ $# -eq 0 ]]; then
            echo -e "${CLR_RED}Error: Target version required. Example: ./migrate.sh goto 2${CLR_RESET}" >&2
            exit 1
        fi
        TARGET_VER="$1"
        echo -e "${CLR_CYAN}▶ Migrating directly to version $TARGET_VER...${CLR_RESET}"
        run_migrate goto "$TARGET_VER"
        echo -e "${CLR_GREEN}✔ Migrated to version $TARGET_VER.${CLR_RESET}"
        ;;

    version)
        echo -e "${CLR_CYAN}▶ Checking current database schema version...${CLR_RESET}"
        set +e
        OUTPUT=$(run_migrate version 2>&1)
        EXIT_CODE=$?
        set -e

        if (( EXIT_CODE == 0 )); then
            echo -e "  Current Version : ${CLR_BOLD}${CLR_GREEN}${OUTPUT}${CLR_RESET}"
        else
            if echo "$OUTPUT" | grep -qi "no migration"; then
                echo -e "  Current Version : ${CLR_YELLOW}0 (No migrations applied yet)${CLR_RESET}"
            else
                echo -e "${CLR_RED}  Error checking version: ${OUTPUT}${CLR_RESET}"
                exit $EXIT_CODE
            fi
        fi
        ;;

    force)
        if [[ $# -eq 0 ]]; then
            echo -e "${CLR_RED}Error: Target version required to clear dirty state. Example: ./migrate.sh force 3${CLR_RESET}" >&2
            exit 1
        fi
        TARGET_VER="$1"
        echo -e "${CLR_YELLOW}⚠ Forcing schema version to $TARGET_VER (clearing dirty state)...${CLR_RESET}"
        run_migrate force "$TARGET_VER"
        echo -e "${CLR_GREEN}✔ Dirty state cleared. Database forced to version $TARGET_VER.${CLR_RESET}"
        ;;

    status)
        echo -e "${CLR_CYAN}${CLR_BOLD}📊 Migration Pipeline Status${CLR_RESET}"
        echo -e "  Migrations Dir : $MIGRATIONS_DIR"
        echo -e "  Database Target: $DB_NAME on ${DB_HOST}:${DB_PORT}\n"

        # List local files
        echo -e "${CLR_BOLD}Local Migration Files:${CLR_RESET}"
        find "$MIGRATIONS_DIR" -maxdepth 1 -name "*.sql" | sort | while IFS= read -r f; do
            echo "  • $(basename "$f")"
        done
        echo ""

        # Check DB version
        set +e
        CURRENT_VER=$(run_migrate version 2>&1)
        set -e
        echo -e "Database Applied Version: ${CLR_BOLD}${CURRENT_VER}${CLR_RESET}\n"
        ;;

    create)
        if [[ $# -eq 0 ]]; then
            echo -e "${CLR_RED}Error: Migration name required. Example: ./migrate.sh create add_invoices${CLR_RESET}" >&2
            exit 1
        fi
        NAME="$1"
        mkdir -p "$MIGRATIONS_DIR"

        # Count existing migrations to format sequential prefix
        COUNT=$(find "$MIGRATIONS_DIR" -maxdepth 1 -name "*.up.sql" | wc -l | tr -d ' ')
        NEXT_SEQ=$((COUNT + 1))
        PREFIX=$(printf "%06d" "$NEXT_SEQ")

        UP_FILE="$MIGRATIONS_DIR/${PREFIX}_${NAME}.up.sql"
        DOWN_FILE="$MIGRATIONS_DIR/${PREFIX}_${NAME}.down.sql"

        cat <<EOF > "$UP_FILE"
-- Migration ${PREFIX}: ${NAME} (UP)

-- TODO: Write forward schema migration DDL
EOF

        cat <<EOF > "$DOWN_FILE"
-- Migration ${PREFIX}: ${NAME} (DOWN)

-- TODO: Write inverse rollback DDL
EOF

        echo -e "${CLR_GREEN}✔ Created migration pair:${CLR_RESET}"
        echo -e "  UP   : $UP_FILE"
        echo -e "  DOWN : $DOWN_FILE"
        ;;

    help|-h|--help)
        show_help
        exit 0
        ;;

    *)
        echo -e "${CLR_RED}Unknown command: $COMMAND${CLR_RESET}" >&2
        show_help
        exit 1
        ;;
esac
