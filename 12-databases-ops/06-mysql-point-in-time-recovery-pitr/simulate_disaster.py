#!/usr/bin/env python3
"""
simulate_disaster.py - Automated Disaster Simulation & Live Workload Generator

1. Validates initial baseline data in MySQL (ecommerce_db).
2. Generates a consistent baseline backup via mysqldump with --flush-logs and binlog coordinate tracking.
3. Injects live, valid e-commerce transactions (orders, payments, audit events) across multiple timestamps.
4. Executes a catastrophic human error: DROP TABLE orders; at timestamp T_disaster.
5. Saves disaster metadata (expected recovered order counts, timestamps) for PITR verification.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_CYAN = "\033[1;36m"
CLR_YELLOW = "\033[1;33m"
CLR_RED = "\033[1;31m"
CLR_GRAY = "\033[0;90m"


def run_mysql_query(query, db="ecommerce_db", root_password="rootpassword", container_name="mysql-pitr-db"):
    """Executes a SQL query via docker exec mysql CLI."""
    cmd = [
        "docker", "exec", container_name,
        "mysql", "-u", "root", f"-p{root_password}", "-D", db, "-N", "-e", query
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"MySQL Query Failed: {res.stderr.strip()}")
    return res.stdout.strip()


def run_mysql_admin(command, root_password="rootpassword", container_name="mysql-pitr-db"):
    """Runs a mysqladmin command."""
    cmd = [
        "docker", "exec", container_name,
        "mysqladmin", "-u", "root", f"-p{root_password}", command
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.returncode == 0


def create_baseline_backup(backup_dir, root_password="rootpassword", container_name="mysql-pitr-db"):
    """
    Executes mysqldump with --single-transaction, --flush-logs, and --master-data=2
    to create a consistent non-locking snapshot and rotate the binlog.
    """
    os.makedirs(backup_dir, exist_ok=True)
    backup_file = os.path.join(backup_dir, "baseline_backup.sql")

    # In MySQL 8.0/8.4, --master-data=2 or --source-data=2 flushes logs and records binary log coordinates
    dump_cmd = [
        "docker", "exec", container_name,
        "mysqldump", "-u", "root", f"-p{root_password}",
        "--single-transaction",
        "--flush-logs",
        "--master-data=2",
        "--databases", "ecommerce_db"
    ]
    
    with open(backup_file, "w", encoding="utf-8") as f:
        res = subprocess.run(dump_cmd, stdout=f, stderr=subprocess.PIPE, text=True)
    
    if res.returncode != 0:
        # Fallback to --source-data=2 for MySQL 8.4+
        dump_cmd_84 = [
            "docker", "exec", container_name,
            "mysqldump", "-u", "root", f"-p{root_password}",
            "--single-transaction",
            "--flush-logs",
            "--source-data=2",
            "--databases", "ecommerce_db"
        ]
        with open(backup_file, "w", encoding="utf-8") as f:
            res = subprocess.run(dump_cmd_84, stdout=f, stderr=subprocess.PIPE, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"mysqldump failed: {res.stderr}")

    return backup_file


def get_binlog_status(root_password="rootpassword", container_name="mysql-pitr-db"):
    """Queries SHOW MASTER STATUS / SHOW BINARY LOG STATUS."""
    try:
        out = run_mysql_query("SHOW MASTER STATUS;", db="", root_password=root_password, container_name=container_name)
    except Exception:
        out = run_mysql_query("SHOW BINARY LOG STATUS;", db="", root_password=root_password, container_name=container_name)
    
    parts = out.split()
    if len(parts) >= 2:
        return {"file": parts[0], "position": int(parts[1])}
    return {"file": "unknown", "position": 0}


def inject_live_transactions(count=25, root_password="rootpassword", container_name="mysql-pitr-db"):
    """Streams live transactional customer orders into the active database."""
    customers_raw = run_mysql_query("SELECT id FROM customers;", root_password=root_password, container_name=container_name)
    customer_ids = [int(cid.strip()) for cid in customers_raw.splitlines() if cid.strip().isdigit()]
    
    if not customer_ids:
        customer_ids = [1, 2, 3, 4, 5]

    inserted_orders = []
    
    for i in range(1, count + 1):
        cid = customer_ids[(i - 1) % len(customer_ids)]
        amount = round(10.0 * i + 4.99, 2)
        status = "COMPLETED" if i % 3 != 0 else "PROCESSING"
        
        sql = (
            f"INSERT INTO orders (customer_id, amount, status, created_at) "
            f"VALUES ({cid}, {amount}, '{status}', NOW()); "
            f"INSERT INTO audit_log (action, details, created_at) "
            f"VALUES ('ORDER_PLACED', 'Order #{i} placed by Customer #{cid} for ${amount}', NOW());"
        )
        run_mysql_query(sql, root_password=root_password, container_name=container_name)
        inserted_orders.append({"order_idx": i, "customer_id": cid, "amount": amount, "status": status})
        time.sleep(0.05)  # Small gap between transactions to ensure clean binlog sequence

    return inserted_orders


def trigger_accidental_drop_table(root_password="rootpassword", container_name="mysql-pitr-db"):
    """Simulates a catastrophic DBA / developer human error: DROP TABLE orders;"""
    disaster_time = datetime.now(timezone.utc).isoformat()
    drop_sql = (
        "INSERT INTO audit_log (action, details, created_at) VALUES ('ACCIDENTAL_ERROR', 'Developer dropped orders table by mistake!', NOW()); "
        "DROP TABLE orders;"
    )
    run_mysql_query(drop_sql, root_password=root_password, container_name=container_name)
    return disaster_time


def main():
    parser = argparse.ArgumentParser(description="MySQL Disaster Simulator & Workload Generator for PITR.")
    parser.add_argument("--root-password", default=os.getenv("MYSQL_ROOT_PASSWORD", "rootpassword"))
    parser.add_argument("--container", default="mysql-pitr-db")
    parser.add_argument("--backup-dir", default="./backups")
    parser.add_argument("--transactions", type=int, default=25, help="Number of live transactions to inject (default: 25)")
    parser.add_argument("--json", action="store_true", help="Output disaster metadata in JSON format")

    args = parser.parse_args()

    if not args.json:
        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  💥 MySQL Disaster Simulation & Live Workload Generator{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

    # Step 1: Verify Initial Baseline
    if not args.json:
        print(f"{CLR_YELLOW}▶ [1/4] Verifying Baseline Data in 'ecommerce_db'...{CLR_RESET}")
    
    baseline_orders_cnt = int(run_mysql_query("SELECT COUNT(*) FROM orders;", root_password=args.root_password, container_name=args.container))
    baseline_customers_cnt = int(run_mysql_query("SELECT COUNT(*) FROM customers;", root_password=args.root_password, container_name=args.container))
    
    if not args.json:
        print(f"  • Baseline Customers : {CLR_BOLD}{baseline_customers_cnt}{CLR_RESET}")
        print(f"  • Baseline Orders    : {CLR_BOLD}{baseline_orders_cnt}{CLR_RESET}")

    # Step 2: Create Full Baseline Backup
    if not args.json:
        print(f"\n{CLR_YELLOW}▶ [2/4] Generating Full Baseline Backup with --flush-logs...{CLR_RESET}")
    
    backup_path = create_baseline_backup(args.backup_dir, root_password=args.root_password, container_name=args.container)
    binlog_at_backup = get_binlog_status(root_password=args.root_password, container_name=args.container)
    
    if not args.json:
        print(f"  • Backup Saved To    : {CLR_GREEN}{backup_path}{CLR_RESET}")
        print(f"  • Active Binlog File : {CLR_BOLD}{binlog_at_backup['file']}{CLR_RESET} (Position: {binlog_at_backup['position']})")

    # Step 3: Stream Live Transactions
    if not args.json:
        print(f"\n{CLR_YELLOW}▶ [3/4] Streaming {args.transactions} Live Valid E-Commerce Transactions...{CLR_RESET}")
    
    inserted = inject_live_transactions(count=args.transactions, root_password=args.root_password, container_name=args.container)
    total_valid_orders = baseline_orders_cnt + len(inserted)
    
    if not args.json:
        print(f"  • Injected Orders    : {CLR_GREEN}+{len(inserted)} orders{CLR_RESET}")
        print(f"  • Expected Total     : {CLR_BOLD}{total_valid_orders} orders{CLR_RESET} to be recovered")

    # Step 4: Execute Catastrophic Disaster
    if not args.json:
        print(f"\n{CLR_RED}{CLR_BOLD}▶ [4/4] 💥 Simulating Human Error: Executing 'DROP TABLE orders;'...{CLR_RESET}")
    
    disaster_ts = trigger_accidental_drop_table(root_password=args.root_password, container_name=args.container)
    binlog_after_disaster = get_binlog_status(root_password=args.root_password, container_name=args.container)
    
    if not args.json:
        print(f"  • Disaster Timestamp : {CLR_RED}{disaster_ts}{CLR_RESET}")
        print(f"  • Active Binlog File : {CLR_BOLD}{binlog_after_disaster['file']}{CLR_RESET}")
        print(f"  • Table Status       : {CLR_RED}TABLE `orders` DESTROYED!{CLR_RESET}")

    metadata = {
        "status": "DISASTER_SIMULATED",
        "database": "ecommerce_db",
        "backup_file": backup_path,
        "binlog_at_backup": binlog_at_backup,
        "binlog_after_disaster": binlog_after_disaster,
        "baseline_orders_count": baseline_orders_cnt,
        "injected_live_orders_count": len(inserted),
        "expected_recovered_orders_total": total_valid_orders,
        "disaster_query": "DROP TABLE orders;",
        "disaster_timestamp": disaster_ts
    }

    metadata_path = os.path.join(args.backup_dir, "disaster_metadata.json")
    with open(metadata_path, "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)

    if args.json:
        print(json.dumps(metadata, indent=2))
    else:
        print(f"\n{CLR_GREEN}{CLR_BOLD}✔ Disaster simulation complete. Metadata recorded in {metadata_path}{CLR_RESET}\n")


if __name__ == "__main__":
    main()
