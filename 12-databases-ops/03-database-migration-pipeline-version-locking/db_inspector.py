#!/usr/bin/env python3
"""
db_inspector.py - Schema Inspector & Evolution Seeder for PostgreSQL

Inspects schema_migrations version table, active schemas, indexes, and constraints.
Provides test data seeding between migration stages to verify non-destructive evolution.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import uuid
from datetime import datetime, timezone

# Optional psycopg2 support
try:
    import psycopg2
    from psycopg2 import sql
    from psycopg2.extras import Json, execute_values
    HAS_PSYCOPG2 = True
except ImportError:
    HAS_PSYCOPG2 = False

# Optional tabulate support
try:
    from tabulate import tabulate
    HAS_TABULATE = True
except ImportError:
    HAS_TABULATE = False

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_CYAN = "\033[1;36m"
CLR_YELLOW = "\033[1;33m"
CLR_RED = "\033[1;31m"
CLR_GRAY = "\033[0;90m"


class DBConnection:
    """Manages queries either via psycopg2 or CLI fallback (psql / docker exec)."""

    def __init__(self, host, port, db, user, password, container="postgres-migration-db"):
        self.host = host
        self.port = str(port)
        self.db = db
        self.user = user
        self.password = password
        self.container = container
        self.use_psycopg = HAS_PSYCOPG2
        self.conn = None

        if self.use_psycopg:
            try:
                self.conn = psycopg2.connect(
                    host=self.host,
                    port=self.port,
                    dbname=self.db,
                    user=self.user,
                    password=self.password,
                    connect_timeout=4
                )
            except Exception:
                self.use_psycopg = False

    def execute_sql(self, sql_script):
        """Executes a SQL script block."""
        if self.use_psycopg and self.conn:
            with self.conn.cursor() as cur:
                cur.execute(sql_script)
            self.conn.commit()
            return

        env = os.environ.copy()
        env["PGPASSWORD"] = self.password
        psql_cmd = ["psql", "-h", self.host, "-p", self.port, "-U", self.user, "-d", self.db, "-v", "ON_ERROR_STOP=1"]
        try:
            res = subprocess.run(psql_cmd, input=sql_script, text=True, capture_output=True, env=env)
            if res.returncode == 0:
                return
        except Exception:
            pass

        docker_cmd = ["docker", "exec", "-i", "-e", f"PGPASSWORD={self.password}", self.container,
                      "psql", "-U", self.user, "-d", self.db, "-v", "ON_ERROR_STOP=1"]
        res = subprocess.run(docker_cmd, input=sql_script, text=True, capture_output=True)
        if res.returncode != 0:
            raise RuntimeError(f"SQL execution failed: {res.stderr}")

    def query_rows(self, sql_query):
        """Queries and returns a list of dictionaries."""
        if self.use_psycopg and self.conn:
            with self.conn.cursor() as cur:
                cur.execute(sql_query)
                cols = [desc[0] for desc in cur.description]
                return [dict(zip(cols, row)) for row in cur.fetchall()]

        clean_query = sql_query.strip().rstrip(";")
        json_query = f"SELECT json_agg(t) FROM ({clean_query}) t;"
        scalar = self.query_scalar(json_query)
        if scalar and scalar != "[null]":
            try:
                return json.loads(scalar) or []
            except Exception:
                pass
        return []

    def query_scalar(self, sql_query):
        """Executes a single scalar query returning string value."""
        if self.use_psycopg and self.conn:
            with self.conn.cursor() as cur:
                cur.execute(sql_query)
                res = cur.fetchone()
                return str(res[0]) if res and res[0] is not None else None

        env = os.environ.copy()
        env["PGPASSWORD"] = self.password
        psql_cmd = ["psql", "-h", self.host, "-p", self.port, "-U", self.user, "-d", self.db, "-t", "-A", "-c", sql_query]
        try:
            res = subprocess.run(psql_cmd, capture_output=True, text=True, env=env)
            if res.returncode == 0:
                return res.stdout.strip()
        except Exception:
            pass

        docker_cmd = ["docker", "exec", "-e", f"PGPASSWORD={self.password}", self.container,
                      "psql", "-U", self.user, "-d", self.db, "-t", "-A", "-c", sql_query]
        res = subprocess.run(docker_cmd, capture_output=True, text=True)
        if res.returncode == 0:
            return res.stdout.strip()
        raise RuntimeError(f"Scalar query failed: {res.stderr}")

    def close(self):
        if self.conn:
            self.conn.close()


def get_schema_summary(db):
    """Gathers migration version, tables, row counts, and index metadata."""
    # 1. Check schema_migrations version table
    version = None
    dirty = None
    try:
        ver_rows = db.query_rows("SELECT version, dirty FROM schema_migrations LIMIT 1;")
        if ver_rows:
            version = ver_rows[0].get("version")
            dirty = ver_rows[0].get("dirty")
    except Exception:
        pass

    # 2. Get list of user tables
    table_query = """
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema = 'public' AND table_name != 'schema_migrations'
    ORDER BY table_name;
    """
    tables = [row["table_name"] for row in db.query_rows(table_query)]

    table_details = []
    total_rows = 0
    for tbl in tables:
        count = int(db.query_scalar(f"SELECT COUNT(*) FROM \"{tbl}\";") or 0)
        total_rows += count

        cols = db.query_rows(f"""
            SELECT column_name, data_type, is_nullable
            FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = '{tbl}'
            ORDER BY ordinal_position;
        """)

        indexes = db.query_rows(f"""
            SELECT indexname, indexdef
            FROM pg_indexes
            WHERE schemaname = 'public' AND tablename = '{tbl}';
        """)

        table_details.append({
            "name": tbl,
            "row_count": count,
            "column_count": len(cols),
            "columns": cols,
            "index_count": len(indexes),
            "indexes": indexes
        })

    return {
        "migration_version": version,
        "is_dirty": dirty,
        "table_count": len(tables),
        "total_rows": total_rows,
        "tables": table_details
    }


def print_schema_summary(summary):
    """Prints a formatted report of current schema and migration status."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}🔍 Database Schema & Migration Status{CLR_RESET}")
    ver_str = str(summary["migration_version"]) if summary["migration_version"] is not None else "None"
    dirty_color = CLR_RED if summary["is_dirty"] else CLR_GREEN
    dirty_str = f"{dirty_color}{summary['is_dirty']}{CLR_RESET}"

    print(f"  Applied Migration Version : {CLR_BOLD}{ver_str}{CLR_RESET}")
    print(f"  Dirty State Flag          : {dirty_str}")
    print(f"  Active Application Tables : {CLR_BOLD}{summary['table_count']}{CLR_RESET}")
    print(f"  Total Data Records        : {CLR_BOLD}{summary['total_rows']:,}{CLR_RESET}\n")

    if not summary["tables"]:
        print(f"  {CLR_YELLOW}(No application tables found in public schema){CLR_RESET}\n")
        return

    table_data = []
    for t in summary["tables"]:
        table_data.append([t["name"], f"{t['row_count']:,}", t["column_count"], t["index_count"]])

    headers = ["Table Name", "Row Count", "Columns", "Indexes"]
    if HAS_TABULATE:
        print(tabulate(table_data, headers=headers, tablefmt="fancy_grid"))
    else:
        print(f"{'Table Name':<25} | {'Row Count':<12} | {'Columns':<8} | {'Indexes':<8}")
        print("-" * 60)
        for row in table_data:
            print(f"{row[0]:<25} | {row[1]:<12} | {row[2]:<8} | {row[3]:<8}")
    print()


def seed_test_data(db, silent=False):
    """Populates existing tables with test records depending on current migration level."""
    summary = get_schema_summary(db)
    table_names = {t["name"] for t in summary["tables"]}

    sql_parts = ["BEGIN;"]

    if "users" in table_names:
        for i in range(1, 21):
            u_uuid = str(uuid.uuid4())
            sql_parts.append(
                f"INSERT INTO users (uuid, username, email, full_name, role, is_active) "
                f"VALUES ('{u_uuid}', 'user_{i}', 'user_{i}@example.com', 'Test User {i}', 'customer', TRUE) "
                f"ON CONFLICT (username) DO NOTHING;"
            )

    if "categories" in table_names:
        cats = [("COMP", "Hardware & Compute"), ("NET", "Networking"), ("ACC", "Accessories")]
        for code, name in cats:
            sql_parts.append(
                f"INSERT INTO categories (code, name, description) "
                f"VALUES ('{code}', '{name}', 'Sample category') "
                f"ON CONFLICT (code) DO NOTHING;"
            )

    if "products" in table_names and "categories" in table_names:
        for i in range(1, 11):
            sku = f"SKU-PROD-{i:03d}"
            sql_parts.append(
                f"INSERT INTO products (sku, category_id, name, description, price, stock_quantity) "
                f"SELECT '{sku}', id, 'Product {i}', 'Enterprise hardware', {i * 99.50}, 50 "
                f"FROM categories ORDER BY id LIMIT 1 "
                f"ON CONFLICT (sku) DO NOTHING;"
            )

    if "orders" in table_names and "order_items" in table_names:
        for i in range(1, 16):
            ord_num = f"ORD-2026-{(5000 + i)}"
            sql_parts.append(
                f"INSERT INTO orders (order_number, user_id, status, total_amount, shipping_address) "
                f"SELECT '{ord_num}', id, 'COMPLETED', 199.00, '{{\"city\": \"Buenos Aires\"}}'::jsonb "
                f"FROM users ORDER BY random() LIMIT 1 "
                f"ON CONFLICT (order_number) DO NOTHING;"
            )
            sql_parts.append(
                f"INSERT INTO order_items (order_id, product_id, quantity, unit_price, subtotal) "
                f"SELECT o.id, p.id, 2, p.price, p.price * 2 "
                f"FROM orders o, products p "
                f"WHERE o.order_number = '{ord_num}' "
                f"ORDER BY p.id LIMIT 1;"
            )

    if "audit_logs" in table_names:
        for i in range(1, 26):
            payload = json.dumps({"action": "schema_test", "iteration": i}).replace("'", "''")
            sql_parts.append(
                f"INSERT INTO audit_logs (event_type, entity_name, entity_id, actor_id, payload, ip_address) "
                f"SELECT 'SCHEMA_EVOLUTION', 'users', 1, id, '{payload}'::jsonb, '127.0.0.1'::inet "
                f"FROM users ORDER BY id LIMIT 1;"
            )

    sql_parts.append("COMMIT;")
    db.execute_sql("\n".join(sql_parts))

    if not silent:
        print(f"{CLR_GREEN}✔ Sample records seeded into available tables.{CLR_RESET}")


def main():
    parser = argparse.ArgumentParser(description="Database Schema Inspector & Test Data Seeder.")
    parser.add_argument("--host", default=os.getenv("POSTGRES_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.getenv("POSTGRES_PORT", "5432")))
    parser.add_argument("--db", default=os.getenv("POSTGRES_DB", "migration_test_db"))
    parser.add_argument("--user", default=os.getenv("POSTGRES_USER", "postgres"))
    parser.add_argument("--password", default=os.getenv("POSTGRES_PASSWORD", "postgres"))
    parser.add_argument("--seed", action="store_true", help="Insert test records into existing tables")
    parser.add_argument("--json", action="store_true", help="Output summary in JSON format")
    parser.add_argument("--silent", action="store_true", help="Suppress progress logs")

    args = parser.parse_args()

    db = DBConnection(args.host, args.port, args.db, args.user, args.password)
    try:
        if args.seed:
            seed_test_data(db, silent=args.silent or args.json)

        summary = get_schema_summary(db)

        if args.json:
            print(json.dumps(summary, indent=2))
        elif not args.silent:
            print_schema_summary(summary)

    finally:
        db.close()


if __name__ == "__main__":
    main()
