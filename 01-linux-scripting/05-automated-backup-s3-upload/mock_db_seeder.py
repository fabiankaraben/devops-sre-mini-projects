#!/usr/bin/env python3
"""
mock_db_seeder.py - SQLite Database & Filesystem Asset Seeder

Generates a realistic sample SQLite production database with schema tables
(users, orders, audit_logs) and static asset files to test backup and restoration.
"""

import argparse
import datetime
import os
import random
import sqlite3
import sys

SAMPLE_NAMES = ["alice", "bob", "charlie", "david", "emma", "frank", "grace", "henry", "isabel", "jack"]
ORDER_STATUSES = ["COMPLETED", "PENDING", "PROCESSING", "SHIPPED", "CANCELLED"]


def seed_database(db_path: str, user_count: int = 50, order_count: int = 120):
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Create schema
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            email TEXT NOT NULL,
            role TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
    """)

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            total_amount REAL NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (user_id) REFERENCES users (id)
        )
    """)

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS audit_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            action TEXT NOT NULL,
            user_id INTEGER,
            ip_address TEXT,
            timestamp TEXT NOT NULL
        )
    """)

    # Seed users
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    for i in range(1, user_count + 1):
        uname = f"{random.choice(SAMPLE_NAMES)}_{i}"
        email = f"{uname}@example.com"
        role = "admin" if i == 1 else "customer"
        cursor.execute(
            "INSERT OR IGNORE INTO users (username, email, role, created_at) VALUES (?, ?, ?, ?)",
            (uname, email, role, now)
        )

    # Seed orders
    for i in range(1, order_count + 1):
        u_id = random.randint(1, user_count)
        amount = round(random.uniform(10.50, 450.00), 2)
        status = random.choice(ORDER_STATUSES)
        cursor.execute(
            "INSERT INTO orders (user_id, total_amount, status, created_at) VALUES (?, ?, ?, ?)",
            (u_id, amount, status, now)
        )

    # Seed audit logs
    for i in range(1, 50):
        action = random.choice(["USER_LOGIN", "CHECKOUT_INIT", "PASSWORD_RESET", "PROFILE_UPDATE"])
        u_id = random.randint(1, user_count)
        ip = f"192.168.1.{random.randint(2, 250)}"
        cursor.execute(
            "INSERT INTO audit_logs (action, user_id, ip_address, timestamp) VALUES (?, ?, ?, ?)",
            (action, u_id, ip, now)
        )

    conn.commit()

    # Query counts
    cursor.execute("SELECT count(*) FROM users")
    total_users = cursor.fetchone()[0]
    cursor.execute("SELECT count(*) FROM orders")
    total_orders = cursor.fetchone()[0]
    cursor.execute("SELECT count(*) FROM audit_logs")
    total_logs = cursor.fetchone()[0]

    conn.close()

    print(f"[mock_db_seeder] Seeded database '{db_path}':")
    print(f"  - Users      : {total_users}")
    print(f"  - Orders     : {total_orders}")
    print(f"  - Audit Logs : {total_logs}")
    return {"users": total_users, "orders": total_orders, "audit_logs": total_logs}


def seed_filesystem_assets(uploads_dir: str):
    os.makedirs(uploads_dir, exist_ok=True)
    sample_files = [
        ("avatar_01.png", b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDRSampleAvatarData"),
        ("invoice_101.pdf", b"%PDF-1.4 Mock Invoice Content for Testing Backups"),
        ("config_meta.json", b'{"service": "app-production", "version": "1.4.2", "region": "us-east-1"}'),
        ("readme.txt", b"Production static assets folder for backup verification.")
    ]

    for fname, content in sample_files:
        fpath = os.path.join(uploads_dir, fname)
        with open(fpath, "wb") as f:
            f.write(content)

    print(f"[mock_db_seeder] Seeded {len(sample_files)} asset files into '{uploads_dir}'.")


def verify_database(db_path: str):
    if not os.path.exists(db_path):
        print(f"[ERROR] Database file not found: {db_path}", file=sys.stderr)
        return False

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("PRAGMA integrity_check;")
    res = cursor.fetchone()[0]
    if res != "ok":
        print(f"[ERROR] Database integrity check failed: {res}", file=sys.stderr)
        conn.close()
        return False

    cursor.execute("SELECT count(*) FROM users")
    users = cursor.fetchone()[0]
    cursor.execute("SELECT count(*) FROM orders")
    orders = cursor.fetchone()[0]
    conn.close()

    print(f"[mock_db_seeder] Verification passed for '{db_path}': integrity=ok, users={users}, orders={orders}.")
    return True


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    default_db = os.path.join(base_dir, "data", "app_production.db")
    default_uploads = os.path.join(base_dir, "data", "uploads")

    parser = argparse.ArgumentParser(description="Seed mock database and assets for backup testing.")
    parser.add_argument("--db-path", default=default_db, help="Path to SQLite database")
    parser.add_argument("--uploads-dir", default=default_uploads, help="Path to assets folder")
    parser.add_argument("--users", type=int, default=50, help="Number of users to seed (default: 50)")
    parser.add_argument("--orders", type=int, default=120, help="Number of orders to seed (default: 120)")
    parser.add_argument("--verify", action="store_true", help="Verify existing database integrity")

    args = parser.parse_args()

    if args.verify:
        sys.exit(0 if verify_database(args.db_path) else 1)

    seed_database(args.db_path, args.users, args.orders)
    seed_filesystem_assets(args.uploads_dir)


if __name__ == "__main__":
    main()
