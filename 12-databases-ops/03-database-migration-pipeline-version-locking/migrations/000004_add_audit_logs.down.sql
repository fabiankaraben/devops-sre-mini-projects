-- Migration 000004: Rollback audit_logs table (DOWN)

DROP TABLE IF EXISTS audit_logs CASCADE;
