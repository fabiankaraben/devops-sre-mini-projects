#!/usr/bin/env python3
"""
continuous_traffic_runner.py - Continuous Multi-Threaded Traffic Generator & SRE Monitor

Simulates production concurrent read/write traffic against the Web API during
zero-downtime database schema refactoring using Python standard library (urllib).
Tracks request success rates, latencies, and asserts 100.00% uptime (0 dropped transactions).
"""

import argparse
import json
import os
import random
import sys
import threading
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

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

FIRST_NAMES = ["Emma", "Liam", "Noah", "Olivia", "Ethan", "Ava", "Lucas", "Mia", "Oliver", "Amelia", "Mateo", "Sophia"]
LAST_NAMES = ["Garcia", "Smith", "Johnson", "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson"]


class TrafficMetrics:
    def __init__(self):
        self.lock = threading.Lock()
        self.total_requests = 0
        self.successful_reads = 0
        self.successful_writes = 0
        self.failed_requests = 0
        self.errors = []
        self.latencies_ms = []

    def record_success(self, req_type, latency_ms):
        with self.lock:
            self.total_requests += 1
            if req_type == "read":
                self.successful_reads += 1
            else:
                self.successful_writes += 1
            self.latencies_ms.append(latency_ms)

    def record_failure(self, req_type, status_code, err_msg):
        with self.lock:
            self.total_requests += 1
            self.failed_requests += 1
            self.errors.append({"type": req_type, "status": status_code, "error": err_msg, "time": time.time()})


def worker_loop(base_url, metrics, stop_event, worker_id):
    while not stop_event.is_set():
        req_type = "read" if random.random() < 0.70 else "write"
        t0 = time.perf_counter()

        try:
            if req_type == "read":
                endpoint = "/users" if random.random() < 0.85 else "/schema"
                req = urllib.request.Request(f"{base_url}{endpoint}", method="GET")
                with urllib.request.urlopen(req, timeout=2.5) as resp:
                    latency = (time.perf_counter() - t0) * 1000.0
                    if resp.status == 200:
                        metrics.record_success("read", latency)
                    else:
                        metrics.record_failure("read", resp.status, f"HTTP {resp.status}")
            else:
                # Write traffic
                first = random.choice(FIRST_NAMES)
                last = random.choice(LAST_NAMES)
                rand_num = random.randint(10000, 99999)
                email = f"load_{worker_id}_{rand_num}@example.com"

                if random.random() < 0.5:
                    payload = {"full_name": f"{first} {last}", "email": email}
                else:
                    payload = {"first_name": first, "last_name": last, "email": email}

                data = json.dumps(payload).encode("utf-8")
                req = urllib.request.Request(
                    f"{base_url}/users",
                    data=data,
                    headers={"Content-Type": "application/json"},
                    method="POST"
                )
                with urllib.request.urlopen(req, timeout=2.5) as resp:
                    latency = (time.perf_counter() - t0) * 1000.0
                    if resp.status == 201:
                        metrics.record_success("write", latency)
                    else:
                        metrics.record_failure("write", resp.status, f"HTTP {resp.status}")

        except urllib.error.HTTPError as he:
            metrics.record_failure(req_type, he.code, f"HTTPError {he.code}: {he.reason}")
        except Exception as e:
            metrics.record_failure(req_type, 0, str(e))

        time.sleep(random.uniform(0.01, 0.03))


def run_traffic(base_url, duration_sec, concurrency):
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🚀 Continuous Traffic Simulator & Zero-Downtime Monitor{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  • Target URL       : {base_url}")
    print(f"  • Concurrent Threads: {concurrency}")
    print(f"  • Test Duration    : {duration_sec} seconds")
    print(f"  • Traffic Mix      : 70% Reads / 30% Writes")
    print("----------------------------------------------------------------------")

    metrics = TrafficMetrics()
    stop_event = threading.Event()
    threads = []

    for wid in range(concurrency):
        t = threading.Thread(target=worker_loop, args=(base_url, metrics, stop_event, wid), daemon=True)
        threads.append(t)
        t.start()

    start_time = time.time()
    try:
        while time.time() - start_time < duration_sec:
            elapsed = time.time() - start_time
            with metrics.lock:
                tot = metrics.total_requests
                fail = metrics.failed_requests
                rps = tot / max(1.0, elapsed)
            print(f"\r  [RUNNING] Elapsed: {elapsed:.1f}s | Requests: {tot} | Failures: {fail} | Rate: {rps:.1f} req/s", end="", flush=True)
            time.sleep(0.5)
    finally:
        stop_event.set()
        for t in threads:
            t.join(timeout=1.0)

    total_time = time.time() - start_time
    print(f"\n----------------------------------------------------------------------\n")

    # Compute Statistics
    lats = metrics.latencies_ms
    avg_lat = sum(lats) / len(lats) if lats else 0.0
    lats_sorted = sorted(lats) if lats else [0.0]
    p50 = lats_sorted[int(len(lats_sorted) * 0.50)]
    p95 = lats_sorted[int(len(lats_sorted) * 0.95)]
    p99 = lats_sorted[int(len(lats_sorted) * 0.99)]
    max_lat = max(lats) if lats else 0.0
    min_lat = min(lats) if lats else 0.0

    success_total = metrics.successful_reads + metrics.successful_writes
    availability_pct = (success_total / max(1, metrics.total_requests)) * 100.0
    throughput_rps = metrics.total_requests / max(1.0, total_time)

    # Save JSON Report
    os.makedirs("reports", exist_ok=True)
    report_data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "duration_seconds": round(total_time, 2),
        "total_requests": metrics.total_requests,
        "successful_reads": metrics.successful_reads,
        "successful_writes": metrics.successful_writes,
        "failed_requests": metrics.failed_requests,
        "availability_percentage": round(availability_pct, 4),
        "throughput_rps": round(throughput_rps, 2),
        "latency_ms": {
            "min": round(min_lat, 2),
            "avg": round(avg_lat, 2),
            "p50": round(p50, 2),
            "p95": round(p95, 2),
            "p99": round(p99, 2),
            "max": round(max_lat, 2)
        },
        "errors": metrics.errors[:10]
    }
    with open("reports/traffic_benchmark_report.json", "w") as f:
        json.dump(report_data, f, indent=2)

    # Print Summary Table
    summary_rows = [
        ["Total Requests Executed", str(metrics.total_requests)],
        ["Successful Reads (200 OK)", f"{CLR_GREEN}{metrics.successful_reads}{CLR_RESET}"],
        ["Successful Writes (201 Created)", f"{CLR_GREEN}{metrics.successful_writes}{CLR_RESET}"],
        ["Failed / Dropped Requests", f"{CLR_RED if metrics.failed_requests > 0 else CLR_GREEN}{metrics.failed_requests}{CLR_RESET}"],
        ["System Availability Rate", f"{CLR_GREEN if availability_pct == 100.0 else CLR_RED}{availability_pct:.2f}%{CLR_RESET}"],
        ["Average Throughput", f"{throughput_rps:.1f} req/s"],
        ["Latency (Avg / P95 / Max)", f"{avg_lat:.2f}ms / {p95:.2f}ms / {max_lat:.2f}ms"],
        ["Audit Report Artifact", "reports/traffic_benchmark_report.json"]
    ]

    if HAS_TABULATE:
        print(tabulate(summary_rows, headers=["Benchmark Metric", "Measured Value"], tablefmt="rounded_grid"))
    else:
        print("-" * 65)
        print(f"{'Benchmark Metric':<35} | {'Measured Value'}")
        print("-" * 65)
        for r in summary_rows:
            print(f"{r[0]:<35} | {r[1]}")
        print("-" * 65)

    print(f"\n{CLR_BOLD}======================================================================{CLR_RESET}")
    if metrics.failed_requests == 0 and metrics.total_requests > 0:
        print(f"{CLR_GREEN}{CLR_BOLD}🎉 SUCCESS: 100.00% Availability Achieved with ZERO Dropped Transactions!{CLR_RESET}")
        print(f"{CLR_BOLD}======================================================================{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"{CLR_RED}{CLR_BOLD}✖ FAILED: {metrics.failed_requests} requests failed during migration!{CLR_RESET}")
        print(f"{CLR_BOLD}======================================================================{CLR_RESET}\n")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Continuous Traffic Runner & Availability Monitor.")
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--duration", type=int, default=10, help="Test duration in seconds")
    parser.add_argument("--concurrency", type=int, default=6, help="Number of concurrent worker threads")

    args = parser.parse_args()
    run_traffic(args.url, args.duration, args.concurrency)


if __name__ == "__main__":
    main()
