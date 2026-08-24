#!/usr/bin/env python3
"""
seed_database.py - Realistic Relational Database Seeder for PostgreSQL

Creates a normalized e-commerce database schema with constraints, foreign keys,
indexes, and JSONB fields, and populates it with deterministic synthetic data.
Supports psycopg2 directly and seamlessly falls back to psql CLI / Docker exec.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone

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

CATEGORIES_DATA = [
    ("CAT-COMP", "Computers & Laptops", "High-performance workstations, laptops, and mini-PCs"),
    ("CAT-NET", "Networking Equipment", "Enterprise switches, routers, firewalls, and access points"),
    ("CAT-STOR", "Storage & Memory", "NVMe SSDs, NAS enclosures, and ECC DDR5 memory kits"),
    ("CAT-PERI", "Peripherals & Audio", "Mechanical keyboards, ergonomic mice, and studio monitors"),
    ("CAT-SRE", "DevOps & SRE Gear", "Hardware security keys, debugging dongles, and server racks"),
]

FIRST_NAMES = [
    "Alex", "Beatriz", "Carlos", "Diana", "Eduardo", "Fatima", "Gabriel", "Helena",
    "Ivan", "Julia", "Kenji", "Lucia", "Mateo", "Nadia", "Oliver", "Paula",
    "Quinn", "Rodrigo", "Sofia", "Tomas", "Uma", "Victor", "Wendy", "Xavier", "Yara", "Zack"
]

LAST_NAMES = [
    "Alvarez", "Benitez", "Castillo", "Dominguez", "Espinoza", "Fernandez", "Gomez",
    "Herrera", "Ibarra", "Juarez", "Keller", "Lopez", "Martinez", "Navarro", "Ortiz",
    "Perez", "Quintana", "Ramirez", "Silva", "Torres", "Ugarte", "Vargas", "Williams", "Zhang"
]

CITIES = [
    ("Buenos Aires", "CABA", "Argentina"),
    ("Cordoba", "CBA", "Argentina"),
    ("Rosario", "SF", "Argentina"),
    ("Mendoza", "MDZ", "Argentina"),
    ("Santiago", "RM", "Chile"),
    ("Montevideo", "MO", "Uruguay"),
    ("Sao Paulo", "SP", "Brazil"),
    ("Madrid", "MD", "Spain"),
    ("Austin", "TX", "USA"),
    ("Berlin", "BE", "Germany"),
]

PRODUCT_TEMPLATES = [
    ("Rackmount Server 1U", "CAT-COMP", 1899.99),
    ("Edge Kubernetes Node", "CAT-COMP", 649.50),
    ("Developer Laptop 64GB", "CAT-COMP", 2299.00),
    ("Managed 24-Port 10GbE Switch", "CAT-NET", 899.00),
    ("WireGuard VPN Gateway Router", "CAT-NET", 249.95),
    ("Wi-Fi 7 Enterprise AP", "CAT-NET", 320.00),
    ("4TB Enterprise NVMe SSD", "CAT-STOR", 450.00),
    ("64TB ZFS NAS Enclosure", "CAT-STOR", 1499.00),
    ("32GB DDR5 ECC Memory Module", "CAT-STOR", 185.50),
    ("Split Ergonomic Keyboard", "CAT-PERI", 280.00),
    ("Precision Wireless Trackball", "CAT-PERI", 110.00),
    ("4K IPS UltraWide Monitor", "CAT-PERI", 750.00),
    ("Hardware FIDO2 Security Key", "CAT-SRE", 55.00),
    ("USB Serial Console Dongle", "CAT-SRE", 25.00),
    ("12U Mobile Server Cabinet", "CAT-SRE", 399.00),
]

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    uuid UUID NOT NULL UNIQUE,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'customer',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    sku VARCHAR(50) UNIQUE NOT NULL,
    category_id INT NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
    name VARCHAR(150) NOT NULL,
    description TEXT,
    price NUMERIC(10, 2) NOT NULL CHECK (price >= 0),
    stock_quantity INT NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    order_number VARCHAR(50) UNIQUE NOT NULL,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'PROCESSING', 'SHIPPED', 'DELIVERED', 'CANCELLED')),
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0),
    shipping_address JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS order_items (
    id SERIAL PRIMARY KEY,
    order_id INT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id INT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price >= 0),
    subtotal NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0)
);

CREATE TABLE IF NOT EXISTS audit_logs (
    id SERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    entity_name VARCHAR(50) NOT NULL,
    entity_id INT NOT NULL,
    user_id INT REFERENCES users(id) ON DELETE SET NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id);
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product ON order_items(product_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event ON audit_logs(event_type);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at);
"""

DROP_TABLES_SQL = """
DROP TABLE IF EXISTS audit_logs CASCADE;
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
"""


class DatabaseRunner:
    """Manages queries either via psycopg2 or CLI fallback (psql / docker)."""

    def __init__(self, host, port, db, user, password, container="postgres-primary"):
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
                    connect_timeout=5
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

        # Fallback to psql on host or inside docker
        env = os.environ.copy()
        env["PGPASSWORD"] = self.password
        psql_cmd = ["psql", "-h", self.host, "-p", self.port, "-U", self.user, "-d", self.db, "-v", "ON_ERROR_STOP=1"]
        try:
            res = subprocess.run(psql_cmd, input=sql_script, text=True, capture_output=True, env=env)
            if res.returncode == 0:
                return
        except Exception:
            pass

        # Fallback to docker exec
        docker_cmd = ["docker", "exec", "-i", "-e", f"PGPASSWORD={self.password}", self.container,
                      "psql", "-U", self.user, "-d", self.db, "-v", "ON_ERROR_STOP=1"]
        res = subprocess.run(docker_cmd, input=sql_script, text=True, capture_output=True)
        if res.returncode != 0:
            raise RuntimeError(f"SQL execution failed: {res.stderr}")

    def query_scalar(self, sql_query):
        """Executes a single scalar query returning the string value."""
        if self.use_psycopg and self.conn:
            with self.conn.cursor() as cur:
                cur.execute(sql_query)
                res = cur.fetchone()
                return res[0] if res else None

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


def generate_seed_sql(num_users=50, num_products=30, num_orders=100, num_logs=150, seed=42):
    """Generates synthetic SQL insert commands deterministically."""
    random.seed(seed)
    base_time = datetime.now(timezone.utc) - timedelta(days=60)
    sql_parts = ["BEGIN;"]

    # 1. Categories
    for code, name, desc in CATEGORIES_DATA:
        desc_escaped = desc.replace("'", "''")
        name_escaped = name.replace("'", "''")
        sql_parts.append(
            f"INSERT INTO categories (code, name, description, created_at) "
            f"VALUES ('{code}', '{name_escaped}', '{desc_escaped}', '{base_time.isoformat()}') "
            f"ON CONFLICT (code) DO NOTHING;"
        )

    # 2. Users
    existing_usernames = set()
    roles = ["customer", "customer", "customer", "support", "admin"]
    for i in range(1, num_users + 1):
        fname = random.choice(FIRST_NAMES)
        lname = random.choice(LAST_NAMES)
        uname_base = f"{fname.lower()}.{lname.lower()}"
        uname = uname_base
        suffix = 1
        while uname in existing_usernames:
            uname = f"{uname_base}{suffix}"
            suffix += 1
        existing_usernames.add(uname)

        email = f"{uname}@example.com"
        user_uuid = str(uuid.uuid4())
        role = random.choice(roles)
        created_at = base_time + timedelta(days=random.randint(1, 30), minutes=random.randint(0, 1440))

        metadata = {
            "preferred_locale": random.choice(["en-US", "es-AR", "es-ES", "pt-BR", "de-DE"]),
            "newsletter_subscribed": random.choice([True, False]),
            "tier": random.choice(["standard", "silver", "gold", "platinum"]),
            "last_login_ip": f"192.168.1.{random.randint(10, 250)}"
        }
        meta_json = json.dumps(metadata).replace("'", "''")

        sql_parts.append(
            f"INSERT INTO users (uuid, username, email, full_name, role, is_active, metadata, created_at) "
            f"VALUES ('{user_uuid}', '{uname}', '{email}', '{fname} {lname}', '{role}', TRUE, '{meta_json}'::jsonb, '{created_at.isoformat()}') "
            f"ON CONFLICT (username) DO NOTHING;"
        )

    # 3. Products
    for i in range(1, num_products + 1):
        tpl_name, cat_code, base_price = random.choice(PRODUCT_TEMPLATES)
        variant = f"Gen {random.randint(1, 4)}"
        sku = f"SKU-{cat_code[-4:]}-{i:04d}"
        price = round(base_price * random.uniform(0.85, 1.25), 2)
        stock = random.randint(5, 500)
        created_at = base_time + timedelta(days=random.randint(1, 15))
        name_escaped = f"{tpl_name} ({variant})".replace("'", "''")
        desc_escaped = f"High-quality enterprise grade {tpl_name} built for 24/7 reliability.".replace("'", "''")

        sql_parts.append(
            f"INSERT INTO products (sku, category_id, name, description, price, stock_quantity, is_available, created_at) "
            f"SELECT '{sku}', id, '{name_escaped}', '{desc_escaped}', {price}, {stock}, TRUE, '{created_at.isoformat()}' "
            f"FROM categories WHERE code = '{cat_code}' "
            f"ON CONFLICT (sku) DO NOTHING;"
        )

    # 4. Orders & Order Items
    statuses = ["PENDING", "PROCESSING", "SHIPPED", "DELIVERED", "CANCELLED"]
    status_weights = [0.10, 0.20, 0.25, 0.40, 0.05]

    for i in range(1, num_orders + 1):
        order_number = f"ORD-{base_time.year}-{(10000 + i)}"
        status = random.choices(statuses, weights=status_weights, k=1)[0]
        created_at = base_time + timedelta(days=random.randint(20, 58), hours=random.randint(0, 23))

        city, state, country = random.choice(CITIES)
        shipping_addr = {
            "street": f"{random.randint(100, 9999)} Commerce Way, Suite {random.randint(10, 800)}",
            "city": city,
            "state": state,
            "country": country,
            "postal_code": f"{random.randint(1000, 99999)}"
        }
        addr_json = json.dumps(shipping_addr).replace("'", "''")

        # Insert order selecting random user
        sql_parts.append(
            f"INSERT INTO orders (order_number, user_id, status, total_amount, shipping_address, created_at) "
            f"VALUES ('{order_number}', (SELECT id FROM users ORDER BY random() LIMIT 1), '{status}', 0.00, '{addr_json}'::jsonb, '{created_at.isoformat()}');"
        )

        # Generate 1 to 4 items for this order
        num_items = random.randint(1, 4)
        for _ in range(num_items):
            qty = random.randint(1, 4)
            sql_parts.append(
                f"INSERT INTO order_items (order_id, product_id, quantity, unit_price, subtotal) "
                f"SELECT currval('orders_id_seq'), p.id, {qty}, p.price, round(p.price * {qty}, 2) "
                f"FROM products p ORDER BY random() LIMIT 1;"
            )

        # Update order total amount
        sql_parts.append(
            f"UPDATE orders SET total_amount = (SELECT COALESCE(SUM(subtotal), 0) FROM order_items WHERE order_id = currval('orders_id_seq')) "
            f"WHERE id = currval('orders_id_seq');"
        )

    # 5. Audit Logs
    log_events = [
        ("ORDER_CREATED", "orders"),
        ("ORDER_STATUS_UPDATED", "orders"),
        ("USER_LOGIN", "users"),
        ("INVENTORY_RESTOCKED", "products"),
        ("PRICE_ADJUSTED", "products"),
    ]

    for _ in range(num_logs):
        event, entity = random.choice(log_events)
        log_time = base_time + timedelta(days=random.randint(1, 59), minutes=random.randint(0, 1440))
        payload = {"action": event.lower(), "status": "recorded", "source": "seeder"}
        payload_json = json.dumps(payload).replace("'", "''")

        sql_parts.append(
            f"INSERT INTO audit_logs (event_type, entity_name, entity_id, user_id, payload, created_at) "
            f"VALUES ('{event}', '{entity}', 1, (SELECT id FROM users ORDER BY random() LIMIT 1), '{payload_json}'::jsonb, '{log_time.isoformat()}');"
        )

    sql_parts.append("COMMIT;")
    return "\n".join(sql_parts)


def get_stats(runner):
    """Retrieves record counts, table sizes, and database metadata."""
    tables = ["categories", "users", "products", "orders", "order_items", "audit_logs"]
    stats = []

    version = runner.query_scalar("SELECT version();")
    db_name = runner.query_scalar("SELECT current_database();")
    db_size = runner.query_scalar("SELECT pg_size_pretty(pg_database_size(current_database()));")

    total_rows = 0
    for tbl in tables:
        count_str = runner.query_scalar(f"SELECT COUNT(*) FROM \"{tbl}\";")
        count = int(count_str) if count_str and count_str.isdigit() else 0
        size = runner.query_scalar(f"SELECT pg_size_pretty(pg_total_relation_size('{tbl}'));") or "0 kB"
        total_rows += count
        stats.append({
            "table": tbl,
            "rows": count,
            "size": size
        })

    return {
        "database": db_name,
        "database_size": db_size,
        "version": version,
        "tables": stats,
        "total_rows": total_rows
    }


def print_stats_table(stats):
    """Prints a formatted summary table of database records."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}📊 PostgreSQL Database Summary: '{stats['database']}' ({stats['database_size']}){CLR_RESET}")
    print(f"{CLR_YELLOW}Engine Version:{CLR_RESET} {stats['version'].split(',')[0]}\n")

    table_data = [[item["table"], f"{item['rows']:,}", item["size"]] for item in stats["tables"]]
    table_data.append(["TOTAL", f"{stats['total_rows']:,}", stats["database_size"]])

    if HAS_TABULATE:
        print(tabulate(table_data, headers=["Table Name", "Row Count", "Disk Size"], tablefmt="fancy_grid"))
    else:
        print(f"{'Table Name':<20} | {'Row Count':<12} | {'Disk Size':<10}")
        print("-" * 48)
        for row in table_data:
            print(f"{row[0]:<20} | {row[1]:<12} | {row[2]:<10}")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Realistic PostgreSQL Database Seeder for Backup & Restore Resilience Testing."
    )
    parser.add_argument("--host", default=os.getenv("POSTGRES_PRIMARY_HOST", "localhost"), help="PostgreSQL host (default: localhost)")
    parser.add_argument("--port", type=int, default=int(os.getenv("POSTGRES_PRIMARY_PORT", "5432")), help="PostgreSQL port (default: 5432)")
    parser.add_argument("--db", default=os.getenv("POSTGRES_DB", "production_db"), help="Database name (default: production_db)")
    parser.add_argument("--user", default=os.getenv("POSTGRES_USER", "postgres"), help="Database username (default: postgres)")
    parser.add_argument("--password", default=os.getenv("POSTGRES_PASSWORD", "postgres"), help="Database password (default: postgres)")
    parser.add_argument("--container", default="postgres-primary", help="Container name fallback (default: postgres-primary)")
    parser.add_argument("--users", type=int, default=50, help="Number of users to seed (default: 50)")
    parser.add_argument("--products", type=int, default=30, help="Number of products to seed (default: 30)")
    parser.add_argument("--orders", type=int, default=100, help="Number of orders to seed (default: 100)")
    parser.add_argument("--logs", type=int, default=150, help="Number of audit logs to seed (default: 150)")
    parser.add_argument("--seed", type=int, default=42, help="Random number generator seed (default: 42)")
    parser.add_argument("--clean", action="store_true", help="Drop existing tables before seeding")
    parser.add_argument("--inspect-only", action="store_true", help="Only inspect current database stats without seeding")
    parser.add_argument("--json", action="store_true", help="Output database stats in JSON format")
    parser.add_argument("--silent", action="store_true", help="Suppress progress output")

    args = parser.parse_args()

    try:
        runner = DatabaseRunner(args.host, args.port, args.db, args.user, args.password, args.container)
    except Exception as e:
        print(f"{CLR_RED}❌ Connection initialization failed: {e}{CLR_RESET}", file=sys.stderr)
        sys.exit(1)

    try:
        if not args.inspect_only:
            if not args.silent and not args.json:
                print(f"{CLR_GREEN}🌱 Initializing schema & seeding database '{args.db}' on {args.host}:{args.port}...{CLR_RESET}")

            if args.clean:
                runner.execute_sql(DROP_TABLES_SQL)

            runner.execute_sql(SCHEMA_SQL)

            seed_sql = generate_seed_sql(
                num_users=args.users,
                num_products=args.products,
                num_orders=args.orders,
                num_logs=args.logs,
                seed=args.seed
            )
            runner.execute_sql(seed_sql)

            if not args.silent and not args.json:
                print(f"{CLR_GREEN}✅ Database schema initialized and seeded successfully!{CLR_RESET}")

        stats = get_stats(runner)

        if args.json:
            print(json.dumps(stats, indent=2))
        elif not args.silent:
            print_stats_table(stats)

    finally:
        runner.close()


if __name__ == "__main__":
    main()
