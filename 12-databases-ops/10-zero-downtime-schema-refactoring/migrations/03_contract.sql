-- ==============================================================================
-- 03_contract.sql - Phase 3: Contract Schema & Drop Legacy Artifacts
-- ==============================================================================
-- Executed after 100% of application traffic has cut over to V2 endpoints.
-- Drops database triggers, drops legacy full_name column, and applies NOT NULL.
-- ==============================================================================

\connect users_db;

-- 1. Remove Synchronization Trigger and Function
DROP TRIGGER IF EXISTS sync_user_names_trigger ON users;
DROP FUNCTION IF EXISTS sync_user_names();

-- 2. Drop Legacy Column
ALTER TABLE users DROP COLUMN IF EXISTS full_name;

-- 3. Enforce Strict Constraints on New Schema
ALTER TABLE users ALTER COLUMN first_name SET NOT NULL;
ALTER TABLE users ALTER COLUMN last_name SET NOT NULL;
