-- Migration 000002: Rollback categories and products catalog (DOWN)

DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
