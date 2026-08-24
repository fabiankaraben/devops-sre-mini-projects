-- ==============================================================================
-- 01_expand.sql - Phase 1: Expand Schema & Create Synchronization Triggers
-- ==============================================================================
-- Adds nullable new columns (first_name, last_name) without breaking V1 app.
-- Deploys bidirectional trigger function ensuring writes to either column set
-- are automatically synchronized in real time.
-- ==============================================================================

\connect users_db;

-- 1. Add new columns as NULLABLE (Zero-downtime, no exclusive table lock)
ALTER TABLE users ADD COLUMN IF NOT EXISTS first_name VARCHAR(50);
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_name VARCHAR(50);

-- 2. Create Bidirectional Synchronization Function
CREATE OR REPLACE FUNCTION sync_user_names()
RETURNS TRIGGER AS $$
BEGIN
    -- Scenario A: Legacy V1 Write (Provides full_name, new columns are empty)
    IF NEW.full_name IS NOT NULL AND (NEW.first_name IS NULL OR NEW.last_name IS NULL) THEN
        IF position(' ' in NEW.full_name) > 0 THEN
            NEW.first_name := split_part(NEW.full_name, ' ', 1);
            NEW.last_name  := substring(NEW.full_name from position(' ' in NEW.full_name) + 1);
        ELSE
            NEW.first_name := NEW.full_name;
            NEW.last_name  := '';
        END IF;
    -- Scenario B: Modern V2 Write (Provides first_name & last_name, full_name is empty)
    ELSIF NEW.first_name IS NOT NULL AND NEW.last_name IS NOT NULL AND NEW.full_name IS NULL THEN
        NEW.full_name := trim(NEW.first_name || ' ' || NEW.last_name);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Deploy BEFORE INSERT OR UPDATE Trigger
DROP TRIGGER IF EXISTS sync_user_names_trigger ON users;
CREATE TRIGGER sync_user_names_trigger
    BEFORE INSERT OR UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION sync_user_names();
