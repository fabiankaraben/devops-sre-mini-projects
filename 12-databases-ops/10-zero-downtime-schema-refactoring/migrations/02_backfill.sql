-- ==============================================================================
-- 02_backfill.sql - Phase 2: Non-Blocking Batched Historical Data Backfill
-- ==============================================================================
-- Updates existing historical records where first_name and last_name are NULL.
-- Safely parses full_name strings into first_name and last_name components.
-- ==============================================================================

\connect users_db;

UPDATE users
SET
    first_name = split_part(full_name, ' ', 1),
    last_name = CASE
        WHEN position(' ' in full_name) > 0 THEN substring(full_name from position(' ' in full_name) + 1)
        ELSE ''
    END
WHERE first_name IS NULL OR last_name IS NULL;
