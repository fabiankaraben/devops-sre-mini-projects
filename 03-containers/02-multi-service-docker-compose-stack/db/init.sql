-- ==============================================================================
-- Database Initialization Script for Multi-Service Compose Stack
-- ==============================================================================

CREATE TABLE IF NOT EXISTS items (
    id SERIAL PRIMARY KEY,
    title VARCHAR(120) NOT NULL,
    description TEXT,
    priority VARCHAR(20) DEFAULT 'MEDIUM',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Seed initial records if table is empty
INSERT INTO items (title, description, priority)
SELECT 'Setup Docker Compose Stack', 'Orchestrate multi-tier microservices with custom bridge networks and healthchecks.', 'HIGH'
WHERE NOT EXISTS (SELECT 1 FROM items WHERE title = 'Setup Docker Compose Stack');

INSERT INTO items (title, description, priority)
SELECT 'Implement Cache-Aside Pattern', 'Leverage Redis to accelerate repetitive read queries and invalidate on mutation.', 'HIGH'
WHERE NOT EXISTS (SELECT 1 FROM items WHERE title = 'Implement Cache-Aside Pattern');

INSERT INTO items (title, description, priority)
SELECT 'Verify Volume Persistence', 'Ensure PostgreSQL data survives container crashes and restarts via named volumes.', 'MEDIUM'
WHERE NOT EXISTS (SELECT 1 FROM items WHERE title = 'Verify Volume Persistence');
