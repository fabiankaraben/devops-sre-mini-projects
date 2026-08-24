-- Initialize benchmark database schema & users

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'benchmark_user') THEN
        CREATE ROLE benchmark_user WITH LOGIN ENCRYPTED PASSWORD 'benchmark_password';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'pgbouncer_admin') THEN
        CREATE ROLE pgbouncer_admin WITH LOGIN ENCRYPTED PASSWORD 'admin_password';
    END IF;
END
$$;

GRANT ALL PRIVILEGES ON DATABASE benchmark_db TO postgres;
GRANT ALL PRIVILEGES ON DATABASE benchmark_db TO benchmark_user;

CREATE TABLE IF NOT EXISTS accounts (
    id BIGSERIAL PRIMARY KEY,
    account_number VARCHAR(50) NOT NULL UNIQUE,
    balance NUMERIC(14, 2) NOT NULL DEFAULT 1000.00,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transactions (
    id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES accounts(id),
    amount NUMERIC(12, 2) NOT NULL,
    transaction_type VARCHAR(20) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_accounts_num ON accounts(account_number);
CREATE INDEX IF NOT EXISTS idx_tx_account ON transactions(account_id);

GRANT ALL ON ALL TABLES IN SCHEMA public TO benchmark_user;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO benchmark_user;

INSERT INTO accounts (account_number, balance)
SELECT 'ACC-' || LPAD(i::text, 6, '0'), 1000.00
FROM generate_series(1, 1000) AS i
ON CONFLICT (account_number) DO NOTHING;
