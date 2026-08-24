-- Migration 000003: Rollback orders and order items tables (DOWN)

DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
