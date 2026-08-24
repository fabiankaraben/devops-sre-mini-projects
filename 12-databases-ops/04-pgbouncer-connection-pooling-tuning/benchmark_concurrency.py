#!/usr/bin/env python3
"""
benchmark_concurrency.py - PostgreSQL vs PgBouncer High-Concurrency Benchmark Suite

Benchmarks direct PostgreSQL connections (port 5432) vs PgBouncer connection pooling
(port 6432) under heavy simultaneous client loads (500 concurrent connections).
Demonstrates connection exhaustion (FATAL: sorry, too many clients already) on direct PG (max_connections=50)
versus seamless multiplexing on PgBouncer (max_client_conn=1000, default_pool_size=20).
"""

import argparse
import concurrent.futures
import json
import os
import random
import subprocess
import sys
import threading
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


def execute_worker_transaction(host, port, dbname, user, password, worker_id, iterations=3, hold_sec=0.2, barrier=None):
    """
    Connects to database, synchronizes at barrier with all concurrent workers to hold
    connections simultaneously, executes banking transactions, and returns timings and status.
    """
    connect_start = time.perf_counter()
    latencies = []
    
    if HAS_PSYCOPG2:
        try:
            conn = psycopg2.connect(
                host=host,
                port=port,
                dbname=dbname,
                user=user,
                password=password,
                connect_timeout=3
            )
            connect_duration_ms = (time.perf_counter() - connect_start) * 1000.0
            
            # Wait for all workers to connect simultaneously to test peak concurrency limits
            if barrier:
                try:
                    barrier.wait(timeout=5)
                except Exception:
                    pass

            with conn.cursor() as cur:
                for _ in range(iterations):
                    acc_id = random.randint(1, 1000)
                    tx_start = time.perf_counter()
                    cur.execute("BEGIN;")
                    cur.execute("SELECT balance FROM accounts WHERE id = %s FOR UPDATE;", (acc_id,))
                    cur.execute("UPDATE accounts SET balance = balance + 1.00, updated_at = NOW() WHERE id = %s;", (acc_id,))
                    cur.execute("COMMIT;")
                    latencies.append((time.perf_counter() - tx_start) * 1000.0)
                    if hold_sec > 0:
                        time.sleep(hold_sec / iterations)
            
            conn.close()
            return {
                "worker_id": worker_id,
                "success": True,
                "connect_time_ms": connect_duration_ms,
                "tx_latencies_ms": latencies,
                "error": None
            }
        except Exception as e:
            err_msg = str(e).strip().replace("\n", " ")
            return {
                "worker_id": worker_id,
                "success": False,
                "connect_time_ms": (time.perf_counter() - connect_start) * 1000.0,
                "tx_latencies_ms": [],
                "error": err_msg
            }
    else:
        # Fallback to direct socket / psql script execution
        env = os.environ.copy()
        env["PGPASSWORD"] = password
        sql_cmd = (
            "BEGIN; "
            f"SELECT balance FROM accounts WHERE id = {random.randint(1, 1000)}; "
            f"SELECT pg_sleep({hold_sec}); "
            "COMMIT;"
        )
        psql = [
            "psql", "-h", host, "-p", str(port), "-U", user, "-d", dbname,
            "-v", "ON_ERROR_STOP=1", "-c", sql_cmd
        ]
        res = subprocess.run(psql, capture_output=True, text=True, env=env)
        connect_duration_ms = (time.perf_counter() - connect_start) * 1000.0
        
        if res.returncode == 0:
            return {
                "worker_id": worker_id,
                "success": True,
                "connect_time_ms": connect_duration_ms,
                "tx_latencies_ms": [connect_duration_ms],
                "error": None
            }
        else:
            return {
                "worker_id": worker_id,
                "success": False,
                "connect_time_ms": connect_duration_ms,
                "tx_latencies_ms": [],
                "error": res.stderr.strip().replace("\n", " ")
            }


def run_concurrency_benchmark(target_name, host, port, dbname, user, password, concurrency, iterations=3, hold_sec=0.2, silent=False):
    """Runs concurrent connection workload and computes statistical aggregates."""
    if not silent:
        print(f"\n{CLR_CYAN}▶ Benchmarking {CLR_BOLD}{target_name}{CLR_RESET} (Host: {host}:{port}, DB: {dbname})")
        print(f"  Concurrent Clients: {CLR_BOLD}{concurrency}{CLR_RESET} | Hold Duration: {CLR_BOLD}{hold_sec}s{CLR_RESET}")

    start_time = time.perf_counter()
    results = []
    barrier = threading.Barrier(concurrency) if HAS_PSYCOPG2 else None

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [
            executor.submit(execute_worker_transaction, host, port, dbname, user, password, i, iterations, hold_sec, barrier)
            for i in range(concurrency)
        ]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    total_duration = time.perf_counter() - start_time

    successful = [r for r in results if r["success"]]
    failed = [r for r in results if not r["success"]]

    all_tx_latencies = [lat for r in successful for lat in r["tx_latencies_ms"]]
    all_connect_times = [r["connect_time_ms"] for r in successful]

    # Calculate percentiles
    all_tx_latencies.sort()
    all_connect_times.sort()

    def percentile(lst, p):
        if not lst:
            return 0.0
        k = (len(lst) - 1) * (p / 100.0)
        f = int(k)
        c = f + 1
        if c < len(lst):
            return lst[f] + (k - f) * (lst[c] - lst[f])
        return lst[f]

    success_rate = (len(successful) / concurrency) * 100.0
    total_tx_completed = len(all_tx_latencies)
    tps = total_tx_completed / total_duration if total_duration > 0 else 0.0

    # Categorize errors
    error_summary = {}
    for r in failed:
        err = r["error"] or "Unknown Error"
        if "too many clients" in err or "53300" in err:
            err_key = "FATAL: sorry, too many clients already (max_connections=50 exceeded)"
        elif "connection refused" in err:
            err_key = "Connection Refused"
        elif "timeout" in err.lower():
            err_key = "Connection Timeout"
        else:
            err_key = err[:70] + "..." if len(err) > 70 else err
        error_summary[err_key] = error_summary.get(err_key, 0) + 1

    summary = {
        "target": target_name,
        "host": host,
        "port": port,
        "concurrency": concurrency,
        "total_duration_sec": round(total_duration, 3),
        "total_clients": concurrency,
        "successful_clients": len(successful),
        "failed_clients": len(failed),
        "success_rate_pct": round(success_rate, 2),
        "total_transactions": total_tx_completed,
        "throughput_tps": round(tps, 2),
        "connect_time_ms": {
            "avg": round(sum(all_connect_times) / len(all_connect_times), 2) if all_connect_times else 0,
            "p50": round(percentile(all_connect_times, 50), 2),
            "p95": round(percentile(all_connect_times, 95), 2),
            "p99": round(percentile(all_connect_times, 99), 2),
            "max": round(max(all_connect_times), 2) if all_connect_times else 0,
        },
        "tx_latency_ms": {
            "avg": round(sum(all_tx_latencies) / len(all_tx_latencies), 2) if all_tx_latencies else 0,
            "p50": round(percentile(all_tx_latencies, 50), 2),
            "p95": round(percentile(all_tx_latencies, 95), 2),
            "p99": round(percentile(all_tx_latencies, 99), 2),
            "max": round(max(all_tx_latencies), 2) if all_tx_latencies else 0,
        },
        "errors": error_summary
    }

    return summary


def get_pgbouncer_admin_stats(host, port, user="postgres", password="postgres"):
    """Connects to the special pgbouncer administrative database and extracts stats."""
    pools = []
    stats = []

    try:
        env = os.environ.copy()
        env["PGPASSWORD"] = password
        
        # Query SHOW POOLS
        cmd_pools = ["psql", "-h", host, "-p", str(port), "-U", user, "-d", "pgbouncer", "-A", "-c", "SHOW POOLS;"]
        res = subprocess.run(cmd_pools, capture_output=True, text=True, env=env)
        if res.returncode == 0:
            lines = [l for l in res.stdout.strip().split("\n") if "|" in l]
            if len(lines) > 1:
                headers = lines[0].split("|")
                for line in lines[1:-1]:
                    vals = line.split("|")
                    if len(vals) == len(headers):
                        pools.append(dict(zip(headers, vals)))

        # Query SHOW STATS
        cmd_stats = ["psql", "-h", host, "-p", str(port), "-U", user, "-d", "pgbouncer", "-A", "-c", "SHOW STATS;"]
        res_s = subprocess.run(cmd_stats, capture_output=True, text=True, env=env)
        if res_s.returncode == 0:
            lines = [l for l in res_s.stdout.strip().split("\n") if "|" in l]
            if len(lines) > 1:
                headers = lines[0].split("|")
                for line in lines[1:-1]:
                    vals = line.split("|")
                    if len(vals) == len(headers):
                        stats.append(dict(zip(headers, vals)))
    except Exception:
        pass

    return {"pools": pools, "stats": stats}


def print_comparison_table(direct_res, bouncer_res):
    """Displays side-by-side comparison table."""
    print(f"\n{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  📊 Concurrency Benchmark: Direct PostgreSQL vs PgBouncer Pooling{CLR_RESET}")
    print(f"{CLR_BOLD}======================================================================{CLR_RESET}\n")

    table_data = [
        ["Total Clients Requested", direct_res["total_clients"], bouncer_res["total_clients"]],
        ["Successful Connections", f"{direct_res['successful_clients']} ({direct_res['success_rate_pct']}%)", f"{bouncer_res['successful_clients']} ({bouncer_res['success_rate_pct']}%)"],
        ["Failed Connections", direct_res["failed_clients"], bouncer_res["failed_clients"]],
        ["Total Transactions Done", direct_res["total_transactions"], bouncer_res["total_transactions"]],
        ["Throughput (TPS)", f"{direct_res['throughput_tps']} tx/s", f"{bouncer_res['throughput_tps']} tx/s"],
        ["Total Test Duration", f"{direct_res['total_duration_sec']} s", f"{bouncer_res['total_duration_sec']} s"],
        ["Connection Latency (p50)", f"{direct_res['connect_time_ms']['p50']} ms", f"{bouncer_res['connect_time_ms']['p50']} ms"],
        ["Connection Latency (p95)", f"{direct_res['connect_time_ms']['p95']} ms", f"{bouncer_res['connect_time_ms']['p95']} ms"],
        ["Tx Latency (Avg)", f"{direct_res['tx_latency_ms']['avg']} ms", f"{bouncer_res['tx_latency_ms']['avg']} ms"],
        ["Tx Latency (p95)", f"{direct_res['tx_latency_ms']['p95']} ms", f"{bouncer_res['tx_latency_ms']['p95']} ms"],
    ]

    headers = ["Metric / Dimension", "Direct PostgreSQL (Port 5432)", "PgBouncer Pooled (Port 6432)"]

    if HAS_TABULATE:
        print(tabulate(table_data, headers=headers, tablefmt="fancy_grid"))
    else:
        print(f"{'Metric':<30} | {'Direct PG':<30} | {'PgBouncer':<30}")
        print("-" * 94)
        for row in table_data:
            print(f"{row[0]:<30} | {str(row[1]):<30} | {str(row[2]):<30}")

    if direct_res["errors"]:
        print(f"\n{CLR_RED}{CLR_BOLD}Direct PostgreSQL Error Breakdown (max_connections=50 constraint):{CLR_RESET}")
        for err, count in direct_res["errors"].items():
            print(f"  • {err}: {count} client(s) rejected")

    if bouncer_res["errors"]:
        print(f"\n{CLR_YELLOW}{CLR_BOLD}PgBouncer Error Breakdown:{CLR_RESET}")
        for err, count in bouncer_res["errors"].items():
            print(f"  • {err}: {count} occurrences")
    else:
        print(f"\n{CLR_GREEN}✔ PgBouncer completed all 500 client connections with 0 errors!{CLR_RESET}")


def print_admin_pools(admin_data):
    """Prints PgBouncer SHOW POOLS information."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}🔍 PgBouncer Internal Connection Pools (`SHOW POOLS`){CLR_RESET}")
    pools = admin_data.get("pools", [])
    if not pools:
        print(f"  {CLR_GRAY}(No active pool telemetry available){CLR_RESET}\n")
        return

    table_data = []
    for p in pools:
        table_data.append([
            p.get("database"),
            p.get("user"),
            p.get("cl_active"),
            p.get("cl_waiting"),
            p.get("sv_active"),
            p.get("sv_idle"),
            p.get("pool_mode")
        ])

    headers = ["Database", "User", "Client Active", "Client Waiting", "Server Active", "Server Idle", "Pool Mode"]
    if HAS_TABULATE:
        print(tabulate(table_data, headers=headers, tablefmt="fancy_grid"))
    else:
        print(f"{'DB':<15} | {'User':<10} | {'Cl Active':<10} | {'Cl Wait':<10} | {'Sv Active':<10} | {'Sv Idle':<10} | {'Mode':<12}")
        print("-" * 85)
        for r in table_data:
            print(f"{r[0]:<15} | {r[1]:<10} | {r[2]:<10} | {r[3]:<10} | {r[4]:<10} | {r[5]:<10} | {r[6]:<12}")
    print()


def main():
    parser = argparse.ArgumentParser(description="PostgreSQL vs PgBouncer High-Concurrency Benchmark Suite.")
    parser.add_argument("--pg-host", default=os.getenv("POSTGRES_HOST", "localhost"))
    parser.add_argument("--pg-port", type=int, default=int(os.getenv("POSTGRES_PORT", "5432")))
    parser.add_argument("--bouncer-host", default=os.getenv("PGBOUNCER_HOST", "localhost"))
    parser.add_argument("--bouncer-port", type=int, default=int(os.getenv("PGBOUNCER_PORT", "6432")))
    parser.add_argument("--db", default=os.getenv("POSTGRES_DB", "benchmark_db"))
    parser.add_argument("--user", default=os.getenv("POSTGRES_USER", "postgres"))
    parser.add_argument("--password", default=os.getenv("POSTGRES_PASSWORD", "postgres"))
    parser.add_argument("--concurrency", type=int, default=500, help="Number of concurrent clients (default: 500)")
    parser.add_argument("--iterations", type=int, default=3, help="Transactions per client worker (default: 3)")
    parser.add_argument("--hold-sec", type=float, default=0.2, help="Hold duration per connection in seconds (default: 0.2)")
    parser.add_argument("--target", choices=["both", "direct", "pgbouncer"], default="both", help="Benchmark target")
    parser.add_argument("--admin-stats", action="store_true", help="Display PgBouncer internal pool status")
    parser.add_argument("--json", action="store_true", help="Output summary in JSON format")

    args = parser.parse_args()

    results_payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "concurrency": args.concurrency,
        "iterations_per_client": args.iterations,
        "direct_postgresql": None,
        "pgbouncer": None,
        "admin_stats": None
    }

    if args.target in ["both", "direct"]:
        direct_res = run_concurrency_benchmark(
            "Direct PostgreSQL",
            args.pg_host,
            args.pg_port,
            args.db,
            args.user,
            args.password,
            args.concurrency,
            args.iterations,
            args.hold_sec,
            silent=args.json
        )
        results_payload["direct_postgresql"] = direct_res

    if args.target in ["both", "pgbouncer"]:
        bouncer_res = run_concurrency_benchmark(
            "PgBouncer Pooled",
            args.bouncer_host,
            args.bouncer_port,
            args.db,
            args.user,
            args.password,
            args.concurrency,
            args.iterations,
            args.hold_sec,
            silent=args.json
        )
        results_payload["pgbouncer"] = bouncer_res

    admin_data = get_pgbouncer_admin_stats(args.bouncer_host, args.bouncer_port, args.user, args.password)
    results_payload["admin_stats"] = admin_data

    if args.json:
        print(json.dumps(results_payload, indent=2))
        return

    if args.target == "both":
        print_comparison_table(results_payload["direct_postgresql"], results_payload["pgbouncer"])

    if args.admin_stats or args.target in ["both", "pgbouncer"]:
        print_admin_pools(admin_data)


if __name__ == "__main__":
    main()
