-- Migration 000004: Create audit_logs table with GIN index on JSONB (UP)

CREATE TABLE IF NOT EXISTS audit_logs (
    id BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    entity_name VARCHAR(50) NOT NULL,
    entity_id BIGINT NOT NULL,
    actor_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    ip_address INET,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- GIN index for high-performance JSONB key/value search
CREATE INDEX IF NOT EXISTS idx_audit_logs_payload_gin ON audit_logs USING GIN (payload);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_name, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event ON audit_logs(event_type);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at);
