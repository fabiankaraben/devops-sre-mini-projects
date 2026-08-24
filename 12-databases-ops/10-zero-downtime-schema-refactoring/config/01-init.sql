-- ==============================================================================
-- 01-init.sql - Baseline Database Schema (V1) & Historical Seed Records
-- ==============================================================================

CREATE DATABASE users_db;

\connect users_db;

-- Initial V1 Schema: Single legacy column 'full_name'
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Seed Initial Historical Users
INSERT INTO users (full_name, email) VALUES
('Jane Alice Doe', 'jane.doe@example.com'),
('Michael Robert Clark', 'michael.clark@example.com'),
('Sophia Marie Rodriguez', 'sophia.rodriguez@example.com'),
('David Alexander Wright', 'david.wright@example.com'),
('Elena Victoria Gomez', 'elena.gomez@example.com'),
('Lucas Gabriel Santos', 'lucas.santos@example.com'),
('Olivia Grace Taylor', 'olivia.taylor@example.com'),
('Benjamin Thomas Hall', 'benjamin.hall@example.com'),
('Charlotte Emma Davis', 'charlotte.davis@example.com'),
('William Henry Miller', 'william.miller@example.com');
