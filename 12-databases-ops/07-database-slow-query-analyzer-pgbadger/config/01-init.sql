-- ==============================================================================
-- 01-init.sql - Realistic E-Commerce Schema & Synthetic Seed Data
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 1. Customers Table
CREATE TABLE IF NOT EXISTS customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL UNIQUE,
    tier VARCHAR(50) NOT NULL DEFAULT 'STANDARD',
    country VARCHAR(100) NOT NULL,
    balance NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Products Table
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    category VARCHAR(100) NOT NULL,
    price NUMERIC(10, 2) NOT NULL,
    stock INT NOT NULL DEFAULT 100,
    description TEXT
);

-- 3. Orders Table (Deliberately missing index on customer_id, status, notes for profiling)
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    total_amount NUMERIC(12, 2) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Order Items Table
CREATE TABLE IF NOT EXISTS order_items (
    id SERIAL PRIMARY KEY,
    order_id INT NOT NULL,
    product_id INT NOT NULL,
    quantity INT NOT NULL DEFAULT 1,
    unit_price NUMERIC(10, 2) NOT NULL
);

-- ------------------------------------------------------------------------------
-- Synthetic Seed Generation (Fast set-based bulk inserts via generate_series)
-- ------------------------------------------------------------------------------

-- Seed 5,000 Customers
INSERT INTO customers (name, email, tier, country, balance, created_at)
SELECT
    'Customer_' || i,
    'user_' || i || '@ecommerce-demo.org',
    (ARRAY['STANDARD', 'GOLD', 'PLATINUM', 'VIP'])[(i % 4) + 1],
    (ARRAY['United States', 'Germany', 'Argentina', 'Japan', 'Brazil', 'Canada'])[(i % 6) + 1],
    ROUND((random() * 5000 + 50)::numeric, 2),
    NOW() - (i || ' minutes')::interval
FROM generate_series(1, 5000) AS s(i);

-- Seed 1,000 Products
INSERT INTO products (name, category, price, stock, description)
SELECT
    'Product_' || i,
    (ARRAY['Electronics', 'Books', 'Home & Kitchen', 'Apparel', 'Automotive'])[(i % 5) + 1],
    ROUND((random() * 500 + 9.99)::numeric, 2),
    (i % 200) + 10,
    'High performance item description for product #' || i || ' featuring durable components.'
FROM generate_series(1, 1000) AS s(i);

-- Seed 25,000 Orders (Unindexed foreign keys & text notes for slow seq scans)
INSERT INTO orders (customer_id, total_amount, status, notes, created_at)
SELECT
    (i % 5000) + 1,
    ROUND((random() * 1200 + 15)::numeric, 2),
    (ARRAY['COMPLETED', 'PENDING', 'PROCESSING', 'CANCELLED', 'REFUNDED'])[(i % 5) + 1],
    'Special delivery instructions: ' || (ARRAY['Express courier service requested with promo code DISCOUNT2026', 'Leave package at front porch', 'Standard freight shipping', 'Priority VIP member dispatch'])[(i % 4) + 1],
    NOW() - ((i % 10000) || ' minutes')::interval
FROM generate_series(1, 25000) AS s(i);

-- Seed 50,000 Order Items
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
    (i % 25000) + 1,
    (i % 1000) + 1,
    (i % 5) + 1,
    ROUND((random() * 250 + 5)::numeric, 2)
FROM generate_series(1, 50000) AS s(i);

-- Run ANALYZE to update query planner statistics
ANALYZE customers;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;
