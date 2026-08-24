#!/bin/sh
# ==============================================================================
# init-primary.sh - PostgreSQL Primary Node Initialization
# ==============================================================================
# Executed automatically by PostgreSQL entrypoint during database initialization.
# Configures pg_hba.conf, creates replication role, replication slot, and schema.
# ==============================================================================

set -e

echo "======================================================================"
echo "  🚀 Initializing PostgreSQL Primary Node & Streaming Replication"
echo "======================================================================"

# Ensure WAL archive directory exists
mkdir -p /var/lib/postgresql/wal_archive 2>/dev/null || true

# 1. Update pg_hba.conf to allow streaming replication from replica
echo "" >> "$PGDATA/pg_hba.conf"
echo "# Streaming Replication Rules" >> "$PGDATA/pg_hba.conf"
echo "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host replication all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"

# Execute SQL commands as postgres superuser
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- 2. Create dedicated replication role
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
            CREATE ROLE replicator WITH REPLICATION LOGIN ENCRYPTED PASSWORD 'replicator_password';
            RAISE NOTICE 'Role replicator created successfully.';
        END IF;
    END
    \$\$;

    -- 3. Create physical replication slot if not already present
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'standby_slot_1') THEN
            PERFORM pg_create_physical_replication_slot('standby_slot_1');
            RAISE NOTICE 'Physical replication slot standby_slot_1 created.';
        END IF;
    END
    \$\$;

    -- 4. Create high-throughput financial transactions testbed schema
    CREATE TABLE IF NOT EXISTS financial_transactions (
        id BIGSERIAL PRIMARY KEY,
        transaction_uuid UUID NOT NULL UNIQUE,
        account_id VARCHAR(50) NOT NULL,
        symbol VARCHAR(20) NOT NULL,
        trade_type VARCHAR(10) NOT NULL CHECK (trade_type IN ('BUY', 'SELL')),
        shares INT NOT NULL CHECK (shares > 0),
        price_per_share NUMERIC(12, 4) NOT NULL CHECK (price_per_share >= 0),
        total_amount NUMERIC(16, 4) NOT NULL,
        execution_status VARCHAR(20) NOT NULL DEFAULT 'COMPLETED',
        metadata JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS system_telemetry (
        id BIGSERIAL PRIMARY KEY,
        node_id VARCHAR(50) NOT NULL,
        metric_name VARCHAR(100) NOT NULL,
        metric_value DOUBLE PRECISION NOT NULL,
        tags JSONB NOT NULL,
        recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    -- 5. Create performance indexes
    CREATE INDEX IF NOT EXISTS idx_tx_account ON financial_transactions(account_id);
    CREATE INDEX IF NOT EXISTS idx_tx_symbol ON financial_transactions(symbol);
    CREATE INDEX IF NOT EXISTS idx_tx_created ON financial_transactions(created_at);
    CREATE INDEX IF NOT EXISTS idx_telemetry_node_metric ON system_telemetry(node_id, metric_name);
    CREATE INDEX IF NOT EXISTS idx_telemetry_recorded ON system_telemetry(recorded_at);
EOSQL

echo "======================================================================"
echo "  ✔ Primary node initialization completed successfully."
echo "======================================================================"
