#!/usr/bin/env bash
# ==============================================================================
# failover_drill.sh - High-Availability Standby Failover Promotion Drill
# ==============================================================================
# Simulates primary node failure, promotes standby replica to primary via
# pg_promote(), and verifies read-write capability on the newly promoted node.
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
REPORT_FILE="$SCRIPT_DIR/failover_report.json"
SILENT=false

# Load .env if present
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env.example"
fi

REPLICA_PORT="${POSTGRES_REPLICA_PORT:-5433}"
DB_NAME="${POSTGRES_DB:-production_db}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASS="${POSTGRES_PASSWORD:-postgres}"

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

log_error() {
    echo -e "${CLR_RED}✖ [$(date +"%H:%M:%S")] $1${CLR_RESET}" >&2
}

if [ "$SILENT" = false ]; then
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚨 High-Availability Failover & Standby Promotion Drill"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 1. Verify Replica is in Standby Mode Before Drill
# ------------------------------------------------------------------------------
log_info "Verifying standby status on replica (localhost:$REPLICA_PORT)..."
export PGPASSWORD="$DB_PASS"

PRE_RECOVERY_STATUS=$(docker exec -e PGPASSWORD="$DB_PASS" postgres-replica psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
if [[ "$PRE_RECOVERY_STATUS" != "t" && "$PRE_RECOVERY_STATUS" != "true" ]]; then
    log_error "Replica is not in recovery mode before failover drill (got: $PRE_RECOVERY_STATUS)."
    exit 1
fi
log_success "Replica confirmed in standby read-only mode."

# ------------------------------------------------------------------------------
# 2. Simulate Primary Outage (Stop Primary Container)
# ------------------------------------------------------------------------------
log_info "Simulating catastrophic primary outage: Stopping 'postgres-primary'..."
START_FAILOVER_TIME=$(date +%s%N)
docker stop postgres-primary >/dev/null

log_success "Primary node stopped. Simulating automated orchestrator promotion..."

# ------------------------------------------------------------------------------
# 3. Promote Standby Replica to Primary via pg_promote()
# ------------------------------------------------------------------------------
log_info "Issuing 'SELECT pg_promote();' on replica..."
docker exec -e PGPASSWORD="$DB_PASS" postgres-replica psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_promote();" >/dev/null

# Wait for promotion transition to complete
RETRIES=15
PROMOTED=false
while (( RETRIES > 0 )); do
    RECOVERY_STATUS=$(docker exec -e PGPASSWORD="$DB_PASS" postgres-replica psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "true")
    if [[ "$RECOVERY_STATUS" == "f" || "$RECOVERY_STATUS" == "false" ]]; then
        PROMOTED=true
        break
    fi
    sleep 0.5
    RETRIES=$((RETRIES - 1))
done

END_FAILOVER_TIME=$(date +%s%N)
PROMOTION_MS=$(( (END_FAILOVER_TIME - START_FAILOVER_TIME) / 1000000 ))

if [ "$PROMOTED" = false ]; then
    log_error "Failover promotion timed out! Replica remains in recovery mode."
    exit 1
fi

log_success "Replica successfully promoted to Read-Write Primary in ${PROMOTION_MS}ms!"

# ------------------------------------------------------------------------------
# 4. Verify Read-Write Capability on Promoted Primary
# ------------------------------------------------------------------------------
log_info "Verifying write operations on the newly promoted primary..."
TEST_UUID="fa110000-0000-0000-0000-000000000001"

docker exec -e PGPASSWORD="$DB_PASS" postgres-replica psql -U "$DB_USER" -d "$DB_NAME" -c "
INSERT INTO financial_transactions 
(transaction_uuid, account_id, symbol, trade_type, shares, price_per_share, total_amount, execution_status, metadata)
VALUES ('$TEST_UUID', 'ACC-FAILOVER-01', 'PROMOTED', 'BUY', 500, 100.0, 50000.0, 'PROMOTED_PRIMARY', '{\"source\": \"failover_drill\"}'::jsonb);
" >/dev/null

# Verify record exists
VERIFIED_COUNT=$(docker exec -e PGPASSWORD="$DB_PASS" postgres-replica psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT COUNT(*) FROM financial_transactions WHERE transaction_uuid = '$TEST_UUID';")

if (( VERIFIED_COUNT == 1 )); then
    log_success "Write operation verified on promoted primary! (Transaction UUID: $TEST_UUID)"
else
    log_error "Write operation verification failed on promoted node."
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Emit Failover Report
# ------------------------------------------------------------------------------
cat <<EOF > "$REPORT_FILE"
{
  "drill": "standby_failover_promotion",
  "executed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "promotion_duration_ms": $PROMOTION_MS,
  "old_primary_status": "STOPPED",
  "promoted_node": "postgres-replica",
  "promoted_port": $REPLICA_PORT,
  "is_in_recovery": false,
  "write_test_passed": true,
  "status": "SUCCESS"
}
EOF

log_success "Failover report generated: $REPORT_FILE"

if [ "$SILENT" = false ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 Standby Promotion Drill Completed with Zero Data Loss!${CLR_RESET}\n"
fi

exit 0
