-- Migration 000001: Rollback users table (DOWN)

DROP TABLE IF EXISTS users CASCADE;
