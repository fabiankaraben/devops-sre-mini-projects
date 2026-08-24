#!/bin/sh
# ==============================================================================
# entrypoint-replica.sh - PostgreSQL Standby Replica Initialization & Startup
# ==============================================================================
# Clones primary node database cluster using pg_basebackup with replication slots,
# configures standby.signal, and launches PostgreSQL in Hot Standby mode.
# ==============================================================================

set -e

PRIMARY_HOST="${POSTGRES_PRIMARY_HOST:-postgres-primary}"
PRIMARY_PORT="${POSTGRES_PRIMARY_PORT:-5432}"
REPL_USER="${REPLICATION_USER:-replicator}"
REPL_PASS="${REPLICATION_PASSWORD:-replicator_password}"
REPL_SLOT="${REPLICATION_SLOT:-standby_slot_1}"
DATA_DIR="/var/lib/postgresql/data"

echo "======================================================================"
echo "  🔄 Initializing PostgreSQL Standby Replica Node"
echo "======================================================================"

# Ensure WAL archive directory exists
mkdir -p /var/lib/postgresql/wal_archive
chmod 0700 /var/lib/postgresql/wal_archive
chown -R postgres:postgres /var/lib/postgresql/wal_archive

# If PG_VERSION is missing, initialize standby data directory from primary
if [ ! -s "$DATA_DIR/PG_VERSION" ]; then
    echo "▶ Cold start detected: Waiting for primary node ($PRIMARY_HOST:$PRIMARY_PORT)..."
    
    until pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -q; do
        echo "  Waiting for primary database to become ready..."
        sleep 2
    done

    echo "▶ Executing pg_basebackup from primary ($PRIMARY_HOST:$PRIMARY_PORT)..."
    rm -rf "$DATA_DIR"/* "$DATA_DIR"/.* 2>/dev/null || true

    export PGPASSWORD="$REPL_PASS"
    pg_basebackup -h "$PRIMARY_HOST" \
                  -p "$PRIMARY_PORT" \
                  -U "$REPL_USER" \
                  -D "$DATA_DIR" \
                  -Fp \
                  -Xs \
                  -R \
                  -S "$REPL_SLOT" \
                  -v

    # Append standby parameters to postgresql.auto.conf
    cat <<EOF >> "$DATA_DIR/postgresql.auto.conf"
# Standby Replication Settings
primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$REPL_USER password=$REPL_PASS application_name=postgres_replica_1'
primary_slot_name = '$REPL_SLOT'
hot_standby = on
hot_standby_feedback = on
restore_command = 'test -f /var/lib/postgresql/wal_archive/%f && cp /var/lib/postgresql/wal_archive/%f %p'
EOF

    echo "▶ Setting correct filesystem permissions on $DATA_DIR..."
    chmod 0700 "$DATA_DIR"
    chown -R postgres:postgres "$DATA_DIR"
    echo "✔ pg_basebackup successfully cloned primary cluster into replica."
fi

echo "▶ Starting PostgreSQL server in standby mode..."
if command -v su-exec >/dev/null 2>&1; then
    exec su-exec postgres postgres -D "$DATA_DIR"
elif command -v gosu >/dev/null 2>&1; then
    exec gosu postgres postgres -D "$DATA_DIR"
else
    exec postgres -D "$DATA_DIR"
fi
