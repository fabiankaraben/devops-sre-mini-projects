-- ==============================================================================
-- init.sql - Database Initialization for Payment Service Demo
-- ==============================================================================

CREATE TABLE IF NOT EXISTS customers (
    id SERIAL PRIMARY KEY,
    customer_uuid VARCHAR(64) NOT NULL UNIQUE,
    full_name VARCHAR(128) NOT NULL,
    email VARCHAR(128) NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS payment_transactions (
    id SERIAL PRIMARY KEY,
    transaction_id VARCHAR(64) NOT NULL UNIQUE,
    customer_uuid VARCHAR(64) REFERENCES customers(customer_uuid),
    amount_usd NUMERIC(10, 2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'USD',
    status VARCHAR(32) DEFAULT 'COMPLETED',
    processed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Seed initial records
INSERT INTO customers (customer_uuid, full_name, email)
VALUES
    ('cust-uuid-001', 'Alice Developer', 'alice@example.com'),
    ('cust-uuid-002', 'Bob CloudSec', 'bob@example.com')
ON CONFLICT (customer_uuid) DO NOTHING;

INSERT INTO payment_transactions (transaction_id, customer_uuid, amount_usd, status)
VALUES
    ('tx-9901-live', 'cust-uuid-001', 250.00, 'COMPLETED'),
    ('tx-9902-live', 'cust-uuid-002', 1280.50, 'COMPLETED')
ON CONFLICT (transaction_id) DO NOTHING;
