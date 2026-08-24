#!/usr/bin/env python3
"""
query_workload_generator.py - Multi-Archetype Database Workload Generator

Generates realistic database workloads to demonstrate slow query analysis with pgBadger:
1. Fast indexed queries (Primary Key index lookups < 1ms).
2. Slow unindexed sequential scans (Missing index candidates, text wildcard searches).
3. Analytical grouping & aggregations.
4. Memory-constrained disk sort spills (triggering log_temp_files).
5. Multi-threaded lock contention (triggering log_lock_waits).
"""

import argparse
import concurrent.futures
import os
import random
import subprocess
import sys
import time
from datetime import datetime, timezone

# Optional psycopg2 support
try:
    import psycopg2
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


def execute_sql(host, port, dbname, user, password, sql, container_name="postgres-analyzer-db"):
    """Executes SQL query using psycopg2 if available, or psql via docker exec."""
    start = time.perf_counter()
    if HAS_PSYCOPG2:
        try:
            conn = psycopg2.connect(host=host, port=port, dbname=dbname, user=user, password=password, connect_timeout=3)
            with conn.cursor() as cur:
                cur.execute(sql)
                if cur.description:
                    cur.fetchall()
            conn.commit()
            conn.close()
            return (time.perf_counter() - start) * 1000.0, True, None
        except Exception as e:
            return (time.perf_counter() - start) * 1000.0, False, str(e)
    else:
        cmd = ["docker", "exec", container_name, "psql", "-U", user, "-d", dbname, "-c", sql]
        res = subprocess.run(cmd, capture_output=True, text=True)
        duration_ms = (time.perf_counter() - start) * 1000.0
        return duration_ms, res.returncode == 0, res.stderr.strip()


def run_fast_indexed_workload(host, port, dbname, user, password, count=50):
    """Executes fast Primary Key index lookups (<1ms)."""
    latencies = []
    for _ in range(count):
        cid = random.randint(1, 5000)
        sql = f"SELECT id, name, email, tier, balance FROM customers WHERE id = {cid};"
        dur, ok, _ = execute_sql(host, port, dbname, user, password, sql)
        if ok:
            latencies.append(dur)
    return latencies


def run_slow_seq_scan_workload(host, port, dbname, user, password, count=15):
    """Executes unindexed full table scans and substring queries (Missing index candidate)."""
    latencies = []
    for _ in range(count):
        keyword = "DISCOUNT2026" if random.random() > 0.3 else "porch"
        sql = f"SELECT * FROM orders WHERE notes LIKE '%{keyword}%' ORDER BY total_amount DESC;"
        dur, ok, _ = execute_sql(host, port, dbname, user, password, sql)
        if ok:
            latencies.append(dur)
    return latencies


def run_slow_join_aggregation_workload(host, port, dbname, user, password, count=10):
    """Executes heavy joins on unindexed customer_id and aggregations."""
    latencies = []
    for _ in range(count):
        country = random.choice(["Germany", "United States", "Argentina", "Japan"])
        sql = (
            f"SELECT c.country, o.status, COUNT(o.id) AS total_orders, SUM(o.total_amount) AS revenue "
            f"FROM orders o JOIN customers c ON o.customer_id = c.id "
            f"WHERE c.country = '{country}' "
            f"GROUP BY c.country, o.status "
            f"HAVING SUM(o.total_amount) > 1000 "
            f"ORDER BY revenue DESC;"
        )
        dur, ok, _ = execute_sql(host, port, dbname, user, password, sql)
        if ok:
            latencies.append(dur)
    return latencies


def run_temp_file_sort_spill_workload(host, port, dbname, user, password, count=8):
    """Executes large sorting operations exceeding work_mem=64kB, triggering temp file disk spills."""
    latencies = []
    for _ in range(count):
        sql = "SELECT id, customer_id, total_amount, status, notes FROM orders ORDER BY notes, total_amount, customer_id;"
        dur, ok, _ = execute_sql(host, port, dbname, user, password, sql)
        if ok:
            latencies.append(dur)
    return latencies


def run_lock_contention_workload(host, port, dbname, user, password, count=5):
    """Generates explicit row lock waits between concurrent transactions (triggering log_lock_waits)."""
    latencies = []

    def hold_lock_worker():
        if HAS_PSYCOPG2:
            try:
                conn = psycopg2.connect(host=host, port=port, dbname=dbname, user=user, password=password)
                with conn.cursor() as cur:
                    cur.execute("BEGIN; SELECT id, balance FROM customers WHERE id = 42 FOR UPDATE;")
                    time.sleep(0.3)
                    cur.execute("UPDATE customers SET balance = balance + 1.00 WHERE id = 42; COMMIT;")
                conn.close()
            except Exception:
                pass
        else:
            execute_sql(host, port, dbname, user, password, "BEGIN; SELECT * FROM customers WHERE id = 42 FOR UPDATE; SELECT pg_sleep(0.3); COMMIT;")

    def waiting_update_worker():
        time.sleep(0.05)  # Wait for first worker to acquire lock
        start = time.perf_counter()
        execute_sql(host, port, dbname, user, password, "UPDATE customers SET balance = balance + 2.50 WHERE id = 42;")
        return (time.perf_counter() - start) * 1000.0

    for _ in range(count):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            f1 = executor.submit(hold_lock_worker)
            f2 = executor.submit(waiting_update_worker)
            f1.result()
            dur = f2.result()
            latencies.append(dur)

    return latencies


def main():
    parser = argparse.ArgumentParser(description="Multi-Archetype Query Workload Generator for pgBadger Profiling.")
    parser.add_argument("--host", default=os.getenv("POSTGRES_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.getenv("POSTGRES_PORT", "5432")))
    parser.add_argument("--db", default=os.getenv("POSTGRES_DB", "analyzer_db"))
    parser.add_argument("--user", default=os.getenv("POSTGRES_USER", "postgres"))
    parser.add_argument("--password", default=os.getenv("POSTGRES_PASSWORD", "postgres"))
    parser.add_argument("--scale", type=int, default=1, help="Workload multiplier scale (default: 1)")

    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🚀 Generating Mixed Database Workload for pgBadger Profiling{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

    start_all = time.perf_counter()

    # 1. Fast indexed queries
    print(f"{CLR_YELLOW}▶ [1/5] Executing {50 * args.scale} Fast Indexed Primary Key Queries (<1ms)...{CLR_RESET}")
    fast_lats = run_fast_indexed_workload(args.host, args.port, args.db, args.user, args.password, count=50 * args.scale)
    avg_fast = sum(fast_lats) / len(fast_lats) if fast_lats else 0.0
    print(f"  • Fast Queries Completed : {len(fast_lats)} (Avg Latency: {avg_fast:.2f} ms)")

    # 2. Slow unindexed sequential table scans
    print(f"\n{CLR_YELLOW}▶ [2/5] Executing {15 * args.scale} Slow Unindexed Table Scans (Missing Index Candidates)...{CLR_RESET}")
    slow_seq_lats = run_slow_seq_scan_workload(args.host, args.port, args.db, args.user, args.password, count=15 * args.scale)
    avg_slow = sum(slow_seq_lats) / len(slow_seq_lats) if slow_seq_lats else 0.0
    print(f"  • Slow Queries Completed : {len(slow_seq_lats)} (Avg Latency: {avg_slow:.2f} ms)")

    # 3. Slow joins and analytical aggregations
    print(f"\n{CLR_YELLOW}▶ [3/5] Executing {10 * args.scale} Analytical Joins & Grouping Queries...{CLR_RESET}")
    join_lats = run_slow_join_aggregation_workload(args.host, args.port, args.db, args.user, args.password, count=10 * args.scale)
    avg_join = sum(join_lats) / len(join_lats) if join_lats else 0.0
    print(f"  • Analytical Completed   : {len(join_lats)} (Avg Latency: {avg_join:.2f} ms)")

    # 4. Work_mem disk sort spills (temp files)
    print(f"\n{CLR_YELLOW}▶ [4/5] Executing {8 * args.scale} Large Sort Queries Spilling to Temporary Files (work_mem=64kB)...{CLR_RESET}")
    temp_lats = run_temp_file_sort_spill_workload(args.host, args.port, args.db, args.user, args.password, count=8 * args.scale)
    avg_temp = sum(temp_lats) / len(temp_lats) if temp_lats else 0.0
    print(f"  • Temp Spills Completed  : {len(temp_lats)} (Avg Latency: {avg_temp:.2f} ms)")

    # 5. Multi-threaded lock contention
    print(f"\n{CLR_YELLOW}▶ [5/5] Inducing {5 * args.scale} Transaction Lock Waits (log_lock_waits trigger)...{CLR_RESET}")
    lock_lats = run_lock_contention_workload(args.host, args.port, args.db, args.user, args.password, count=5 * args.scale)
    avg_lock = sum(lock_lats) / len(lock_lats) if lock_lats else 0.0
    print(f"  • Lock Waits Completed   : {len(lock_lats)} (Avg Lock Wait Delay: {avg_lock:.2f} ms)")

    total_duration = time.perf_counter() - start_all
    total_queries = len(fast_lats) + len(slow_seq_lats) + len(join_lats) + len(temp_lats) + len(lock_lats)

    print(f"\n{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_GREEN}{CLR_BOLD}✔ Workload generation completed in {total_duration:.2f} seconds!{CLR_RESET}")
    print(f"  Total Queries Dispatched : {total_queries}")
    print(f"  PostgreSQL Server Logs   : Ready for pgBadger analysis.")
    print(f"{CLR_BOLD}======================================================================{CLR_RESET}\n")


if __name__ == "__main__":
    main()
