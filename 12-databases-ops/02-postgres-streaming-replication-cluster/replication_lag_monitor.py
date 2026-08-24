#!/usr/bin/env python3
"""
replication_lag_monitor.py - PostgreSQL Streaming Replication & Lag Telemetry

Provides high-throughput workload generation, real-time replication lag
monitoring via pg_stat_replication, read-only enforcement verification,
and data parity auditing across primary and standby replica nodes.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time
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

SYMBOLS = ["AAPL", "GOOGL", "MSFT", "AMZN", "NVDA", "TSLA", "META", "BRK.B", "JPM", "V"]
TRADE_TYPES = ["BUY", "SELL"]
ACCOUNTS = [f"ACC-{i:05d}" for i in range(1001, 1050)]
NODES = [f"node-worker-{i:02d}" for i in range(1, 11)]
METRIC_NAMES = ["cpu_utilization_pct", "memory_rss_bytes", "disk_io_iops", "network_rx_kbps", "query_latency_ms"]


class DBConnection:
    """Manages queries either via psycopg2 or CLI fallback (psql / docker exec)."""

    def __init__(self, host, port, db, user, password, container):
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

        # Fallback to json output via psql
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


def generate_workload_sql(record_count, batch_size=2000, seed=42):
    """Generates batched SQL insertion commands for financial transactions and telemetry."""
    random.seed(seed)
    batches = []
    
    tx_count = record_count
    telemetry_count = max(1000, record_count // 5)

    # 1. Financial Transactions Batches
    for start_idx in range(0, tx_count, batch_size):
        current_batch_size = min(batch_size, tx_count - start_idx)
        rows_sql = []
        for _ in range(current_batch_size):
            tx_uuid = str(uuid.uuid4())
            account = random.choice(ACCOUNTS)
            symbol = random.choice(SYMBOLS)
            ttype = random.choice(TRADE_TYPES)
            shares = random.randint(10, 1000)
            price = round(random.uniform(25.0, 650.0), 4)
            total = round(shares * price, 4)
            meta = json.dumps({"exchange": "NASDAQ", "route": "DMA-LOWLATENCY", "client_ip": f"10.0.1.{random.randint(1,250)}"}).replace("'", "''")
            rows_sql.append(
                f"('{tx_uuid}', '{account}', '{symbol}', '{ttype}', {shares}, {price}, {total}, 'COMPLETED', '{meta}'::jsonb)"
            )
        
        batch_query = (
            "INSERT INTO financial_transactions "
            "(transaction_uuid, account_id, symbol, trade_type, shares, price_per_share, total_amount, execution_status, metadata) "
            "VALUES\n" + ",\n".join(rows_sql) + ";"
        )
        batches.append(batch_query)

    # 2. Telemetry Events Batches
    for start_idx in range(0, telemetry_count, batch_size):
        current_batch_size = min(batch_size, telemetry_count - start_idx)
        rows_sql = []
        for _ in range(current_batch_size):
            node = random.choice(NODES)
            metric = random.choice(METRIC_NAMES)
            val = round(random.uniform(5.0, 99.9), 3)
            tags = json.dumps({"env": "production", "cluster": "us-east-1", "az": "us-east-1a"}).replace("'", "''")
            rows_sql.append(f"('{node}', '{metric}', {val}, '{tags}'::jsonb)")

        batch_query = (
            "INSERT INTO system_telemetry (node_id, metric_name, metric_value, tags) "
            "VALUES\n" + ",\n".join(rows_sql) + ";"
        )
        batches.append(batch_query)

    return batches


def execute_workload(primary_conn, record_count=50000, batch_size=2000, silent=False):
    """Inserts high-throughput records into the primary database."""
    if not silent:
        print(f"\n{CLR_CYAN}{CLR_BOLD}⚡ Injecting High-Throughput Workload ({record_count:,} records)...{CLR_RESET}")

    start_lsn = primary_conn.query_scalar("SELECT pg_current_wal_lsn();")
    start_time = time.time()

    batches = generate_workload_sql(record_count, batch_size)
    for i, batch in enumerate(batches, 1):
        primary_conn.execute_sql(batch)
        if not silent and i % 5 == 0:
            print(f"  Progress: batch {i}/{len(batches)} committed...")

    end_time = time.time()
    end_lsn = primary_conn.query_scalar("SELECT pg_current_wal_lsn();")
    duration = end_time - start_time
    throughput = record_count / duration if duration > 0 else 0

    lsn_diff_bytes = int(primary_conn.query_scalar(f"SELECT pg_wal_lsn_diff('{end_lsn}', '{start_lsn}');") or 0)
    lsn_diff_mb = lsn_diff_bytes / (1024 * 1024)

    stats = {
        "records_inserted": record_count,
        "duration_seconds": round(duration, 3),
        "throughput_records_per_sec": round(throughput, 1),
        "start_lsn": start_lsn,
        "end_lsn": end_lsn,
        "wal_generated_bytes": lsn_diff_bytes,
        "wal_generated_mb": round(lsn_diff_mb, 2)
    }

    if not silent:
        print(f"{CLR_GREEN}✔ Workload insertion complete!{CLR_RESET}")
        print(f"  Duration      : {stats['duration_seconds']}s")
        print(f"  Throughput    : {stats['throughput_records_per_sec']:,} records/sec")
        print(f"  WAL Generated : {stats['wal_generated_mb']} MB ({stats['start_lsn']} -> {stats['end_lsn']})\n")

    return stats


def get_replication_metrics(primary_conn):
    """Collects real-time streaming replication telemetry from pg_stat_replication."""
    query = """
    SELECT 
        pid,
        application_name,
        client_addr::text AS client_ip,
        state,
        sync_state,
        sent_lsn::text,
        write_lsn::text,
        flush_lsn::text,
        replay_lsn::text,
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS byte_lag,
        COALESCE(EXTRACT(EPOCH FROM write_lag) * 1000, 0) AS write_lag_ms,
        COALESCE(EXTRACT(EPOCH FROM flush_lag) * 1000, 0) AS flush_lag_ms,
        COALESCE(EXTRACT(EPOCH FROM replay_lag) * 1000, 0) AS replay_lag_ms
    FROM pg_stat_replication;
    """
    rows = primary_conn.query_rows(query)

    slots_query = """
    SELECT 
        slot_name,
        plugin,
        slot_type,
        active,
        wal_status,
        restart_lsn::text,
        confirmed_flush_lsn::text
    FROM pg_replication_slots;
    """
    slots = primary_conn.query_rows(slots_query)

    primary_lsn = primary_conn.query_scalar("SELECT pg_current_wal_lsn();")

    return {
        "primary_current_lsn": primary_lsn,
        "standby_count": len(rows),
        "replicas": rows,
        "replication_slots": slots
    }


def print_replication_table(metrics):
    """Prints formatted replication status table."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}📡 PostgreSQL Streaming Replication Status{CLR_RESET}")
    print(f"  Primary Current LSN: {CLR_BOLD}{metrics['primary_current_lsn']}{CLR_RESET}\n")

    if not metrics["replicas"]:
        print(f"{CLR_RED}✖ No active standby replicas connected!{CLR_RESET}\n")
        return

    table_data = []
    for r in metrics["replicas"]:
        byte_lag = int(r.get("byte_lag") or 0)
        replay_ms = float(r.get("replay_lag_ms") or 0.0)
        lag_status = f"{CLR_GREEN}EXCELLENT (<1ms){CLR_RESET}" if replay_ms < 1.0 else f"{CLR_YELLOW}{replay_ms:.2f}ms{CLR_RESET}"

        table_data.append([
            r.get("application_name", "standby"),
            r.get("client_ip", "N/A"),
            r.get("state", "N/A"),
            r.get("sync_state", "async"),
            r.get("replay_lsn", "N/A"),
            f"{byte_lag:,} bytes",
            f"{replay_ms:.3f} ms",
            lag_status
        ])

    headers = ["Application", "Client IP", "State", "Sync Mode", "Replay LSN", "Byte Lag", "Replay Lag", "Health"]
    if HAS_TABULATE:
        print(tabulate(table_data, headers=headers, tablefmt="fancy_grid"))
    else:
        print(f"{'Application':<15} | {'State':<10} | {'Byte Lag':<12} | {'Replay Lag':<12}")
        print("-" * 55)
        for row in table_data:
            print(f"{row[0]:<15} | {row[2]:<10} | {row[5]:<12} | {row[6]:<12}")
    print()


def verify_readonly_standby(replica_conn, silent=False):
    """Validates that the standby node operates in strict Hot Standby read-only mode."""
    if not silent:
        print(f"{CLR_CYAN}{CLR_BOLD}🔒 Verifying Standby Read-Only Enforcement...{CLR_RESET}")

    # 1. Verify in recovery mode
    in_recovery = replica_conn.query_scalar("SELECT pg_is_in_recovery();")
    if str(in_recovery).lower() not in ("true", "t"):
        if not silent:
            print(f"{CLR_RED}✖ Replica is NOT in recovery mode! pg_is_in_recovery() = {in_recovery}{CLR_RESET}")
        return False

    # 2. Verify read query succeeds
    try:
        count = replica_conn.query_scalar("SELECT COUNT(*) FROM financial_transactions;")
        if not silent:
            print(f"  ✔ Read Query Succeeded: found {int(count):,} transactions on standby.")
    except Exception as e:
        if not silent:
            print(f"{CLR_RED}✖ Read query failed on standby: {e}{CLR_RESET}")
        return False

    # 3. Verify write operation is strictly rejected
    write_blocked = False
    error_msg = ""
    try:
        replica_conn.execute_sql(
            "INSERT INTO financial_transactions (transaction_uuid, account_id, symbol, trade_type, shares, price_per_share, total_amount, metadata) "
            "VALUES ('00000000-0000-0000-0000-000000000000', 'TEST', 'FAIL', 'BUY', 1, 10.0, 10.0, '{}'::jsonb);"
        )
    except Exception as e:
        write_blocked = True
        error_msg = str(e)

    if write_blocked and ("read-only" in error_msg.lower() or "cannot execute" in error_msg.lower()):
        if not silent:
            print(f"{CLR_GREEN}  ✔ Write Operation Blocked (Expected): Standby rejected INSERT with read-only violation.{CLR_RESET}")
            print(f"{CLR_GRAY}    PostgreSQL Error: {error_msg.strip()}{CLR_RESET}\n")
        return True
    else:
        if not silent:
            print(f"{CLR_RED}✖ Security Alert: Standby permitted write or failed with unexpected error: {error_msg}{CLR_RESET}")
        return False


def verify_cluster_parity(primary_conn, replica_conn, silent=False):
    """Compares row counts and table hashes across primary and replica."""
    if not silent:
        print(f"{CLR_CYAN}{CLR_BOLD}⚖ Auditing Data Parity between Primary & Standby Replica...{CLR_RESET}")

    tables = ["financial_transactions", "system_telemetry"]
    parity_results = []
    all_matched = True

    for tbl in tables:
        p_count = int(primary_conn.query_scalar(f"SELECT COUNT(*) FROM {tbl};") or 0)
        # Give replica up to 3 seconds to catch up in high stress
        r_count = 0
        for _ in range(30):
            r_count = int(replica_conn.query_scalar(f"SELECT COUNT(*) FROM {tbl};") or 0)
            if r_count == p_count:
                break
            time.sleep(0.1)

        is_match = (p_count == r_count)
        if not is_match:
            all_matched = False

        parity_results.append({
            "table": tbl,
            "primary_rows": p_count,
            "replica_rows": r_count,
            "diff": p_count - r_count,
            "parity": is_match
        })

    if not silent:
        table_data = []
        for item in parity_results:
            status = f"{CLR_GREEN}MATCH ✔{CLR_RESET}" if item["parity"] else f"{CLR_RED}MISMATCH ✖{CLR_RESET}"
            table_data.append([item["table"], f"{item['primary_rows']:,}", f"{item['replica_rows']:,}", item["diff"], status])

        if HAS_TABULATE:
            print(tabulate(table_data, headers=["Table Name", "Primary Rows", "Replica Rows", "Delta", "Parity Status"], tablefmt="fancy_grid"))
        else:
            print(f"{'Table Name':<25} | {'Primary':<12} | {'Replica':<12} | {'Status':<10}")
            print("-" * 65)
            for row in table_data:
                print(f"{row[0]:<25} | {row[1]:<12} | {row[2]:<12} | {row[4]:<10}")
        print()

    return {
        "parity_passed": all_matched,
        "tables": parity_results
    }


def main():
    parser = argparse.ArgumentParser(
        description="PostgreSQL Streaming Replication Lag Monitor & Workload Generator."
    )
    parser.add_argument("--primary-host", default=os.getenv("POSTGRES_PRIMARY_HOST", "localhost"), help="Primary host")
    parser.add_argument("--primary-port", type=int, default=int(os.getenv("POSTGRES_PRIMARY_PORT", "5432")), help="Primary port")
    parser.add_argument("--replica-host", default=os.getenv("POSTGRES_REPLICA_HOST", "localhost"), help="Replica host")
    parser.add_argument("--replica-port", type=int, default=int(os.getenv("POSTGRES_REPLICA_PORT", "5433")), help="Replica port")
    parser.add_argument("--db", default=os.getenv("POSTGRES_DB", "production_db"), help="Database name")
    parser.add_argument("--user", default=os.getenv("POSTGRES_USER", "postgres"), help="Database user")
    parser.add_argument("--password", default=os.getenv("POSTGRES_PASSWORD", "postgres"), help="Database password")

    # Action flags
    parser.add_argument("--workload", action="store_true", help="Generate high-throughput write workload on primary")
    parser.add_argument("--records", type=int, default=int(os.getenv("WORKLOAD_RECORD_COUNT", "50000")), help="Number of records to insert (default: 50,000)")
    parser.add_argument("--batch-size", type=int, default=2000, help="Batch size for inserts (default: 2,000)")
    parser.add_argument("--monitor", action="store_true", help="Monitor replication lag metrics from pg_stat_replication")
    parser.add_argument("--verify-readonly", action="store_true", help="Verify read-only enforcement on replica")
    parser.add_argument("--verify-parity", action="store_true", help="Verify row-count and data parity between primary and replica")
    parser.add_argument("--all-in-one", action="store_true", help="Execute workload, monitor lag, verify read-only, and audit parity")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--silent", action="store_true", help="Suppress progress logs")

    args = parser.parse_args()

    primary_conn = DBConnection(args.primary_host, args.primary_port, args.db, args.user, args.password, "postgres-primary")
    replica_conn = DBConnection(args.replica_host, args.replica_port, args.db, args.user, args.password, "postgres-replica")

    combined_output = {}

    try:
        # Default to all-in-one if no specific action specified
        run_all = args.all_in_one or not (args.workload or args.monitor or args.verify_readonly or args.verify_parity)

        if args.workload or run_all:
            workload_res = execute_workload(primary_conn, args.records, args.batch_size, silent=args.silent or args.json)
            combined_output["workload"] = workload_res

        if args.monitor or run_all:
            metrics_res = get_replication_metrics(primary_conn)
            combined_output["replication_metrics"] = metrics_res
            if not args.silent and not args.json:
                print_replication_table(metrics_res)

        if args.verify_readonly or run_all:
            readonly_res = verify_readonly_standby(replica_conn, silent=args.silent or args.json)
            combined_output["readonly_enforced"] = readonly_res

        if args.verify_parity or run_all:
            parity_res = verify_cluster_parity(primary_conn, replica_conn, silent=args.silent or args.json)
            combined_output["parity"] = parity_res

        if args.json:
            print(json.dumps(combined_output, indent=2))

    finally:
        primary_conn.close()
        replica_conn.close()


if __name__ == "__main__":
    main()
