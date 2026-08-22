#!/usr/bin/env python3
"""
traffic_simulator.py - Synthetic Multi-Pattern Traffic & Load Generator

Generates customizable HTTP traffic profiles against the instrumented microservice:
1. Steady Baseline Traffic (GET /api/items)
2. Latency Spikes (GET /api/slow)
3. Error Bursts (GET /api/flaky)
4. Worker Pool & Queue Saturation (POST /api/process)
5. Resource Subsystem Errors (POST /api/inject-resource-error)

Zero external dependencies (uses standard library urllib, threading, json).
"""

import argparse
import json
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Dict, List, Optional

# Terminal ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"


class TrafficStats:
    """Thread-safe counter for traffic metrics."""

    def __init__(self):
        self.lock = threading.Lock()
        self.total_requests = 0
        self.success_count = 0
        self.client_error_count = 0  # 4xx
        self.server_error_count = 0  # 5xx
        self.slow_requests_count = 0 # > 500ms
        self.latencies: List[float] = []

    def record(self, status_code: int, duration_s: float):
        with self.lock:
            self.total_requests += 1
            self.latencies.append(duration_s)
            if duration_s >= 0.5:
                self.slow_requests_count += 1

            if 200 <= status_code < 400:
                self.success_count += 1
            elif 400 <= status_code < 500:
                self.client_error_count += 1
            elif status_code >= 500:
                self.server_error_count += 1


def send_http_request(url: str, method: str = "GET", payload: Optional[Dict] = None, timeout: float = 10.0) -> int:
    """Send HTTP request and return status code."""
    data = json.dumps(payload).encode("utf-8") if payload else None
    headers = {"Content-Type": "application/json", "User-Agent": "TrafficSimulator/1.0"}

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as err:
        return err.code
    except Exception:
        return 599


def worker_loop(
    base_url: str,
    scenario: str,
    stop_event: threading.Event,
    stats: TrafficStats,
    worker_id: int,
):
    """Worker thread generating traffic according to specified scenario."""
    while not stop_event.is_set():
        endpoint_type = scenario
        if scenario == "all":
            # Probability distribution for combined scenario
            r = random.random()
            if r < 0.55:
                endpoint_type = "steady"
            elif r < 0.75:
                endpoint_type = "latency-spike"
            elif r < 0.90:
                endpoint_type = "error-burst"
            elif r < 0.96:
                endpoint_type = "queue-saturation"
            else:
                endpoint_type = "resource-errors"

        start_time = time.perf_counter()
        status_code = 200

        try:
            if endpoint_type == "steady":
                status_code = send_http_request(f"{base_url}/api/items?count={random.randint(3, 10)}")
                time.sleep(random.uniform(0.01, 0.05))

            elif endpoint_type == "latency-spike":
                delay = random.uniform(0.6, 1.2)
                status_code = send_http_request(f"{base_url}/api/slow?delay={delay:.2f}&jitter=0.2")
                time.sleep(random.uniform(0.05, 0.1))

            elif endpoint_type == "error-burst":
                status_code = send_http_request(f"{base_url}/api/flaky?error_rate=0.7")
                time.sleep(random.uniform(0.02, 0.08))

            elif endpoint_type == "queue-saturation":
                batch = random.randint(15, 30)
                status_code = send_http_request(
                    f"{base_url}/api/process",
                    method="POST",
                    payload={"batch_size": batch, "task_duration": 0.3},
                )
                time.sleep(random.uniform(0.1, 0.3))

            elif endpoint_type == "resource-errors":
                res = random.choice(["db_pool", "thread_pool", "disk_io"])
                status_code = send_http_request(
                    f"{base_url}/api/inject-resource-error",
                    method="POST",
                    payload={"resource": res, "count": random.randint(1, 3)},
                )
                time.sleep(random.uniform(0.1, 0.2))

        except Exception:
            status_code = 599

        duration = time.perf_counter() - start_time
        stats.record(status_code, duration)


def run_traffic_simulation(
    base_url: str,
    scenario: str,
    duration_s: int,
    concurrency: int,
):
    """Main orchestrator for synthetic load generation."""
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🚗 Synthetic Traffic Generator (RED & USE Workload Simulation){CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  • Target URL    : {CLR_WHITE}{base_url}{CLR_RESET}")
    print(f"  • Scenario      : {CLR_YELLOW}{scenario.upper()}{CLR_RESET}")
    print(f"  • Concurrency   : {CLR_WHITE}{concurrency} worker threads{CLR_RESET}")
    print(f"  • Duration      : {CLR_WHITE}{duration_s} seconds{CLR_RESET}\n")

    stats = TrafficStats()
    stop_event = threading.Event()
    threads: List[threading.Thread] = []

    # Spawn worker threads
    for i in range(concurrency):
        t = threading.Thread(
            target=worker_loop,
            args=(base_url, scenario, stop_event, stats, i + 1),
            daemon=True,
        )
        threads.append(t)
        t.start()

    # Progress monitor loop
    start_time = time.time()
    try:
        while True:
            elapsed = time.time() - start_time
            if elapsed >= duration_s:
                break

            with stats.lock:
                total = stats.total_requests
                success = stats.success_count
                errors = stats.server_error_count
                slow = stats.slow_requests_count
                rps = total / elapsed if elapsed > 0 else 0

            pct_done = min(100.0, (elapsed / duration_s) * 100.0)
            sys.stdout.write(
                f"\r  [{pct_done:5.1f}%] Elapsed: {elapsed:4.1f}s | Sent: {total:5d} req | "
                f"RPS: {rps:5.1f} | {CLR_GREEN}2xx:{success:4d}{CLR_RESET} | "
                f"{CLR_RED}5xx:{errors:3d}{CLR_RESET} | {CLR_YELLOW}Slow(>0.5s):{slow:3d}{CLR_RESET} "
            )
            sys.stdout.flush()
            time.sleep(0.5)

    finally:
        stop_event.set()
        for t in threads:
            t.join(timeout=2.0)

    elapsed = time.time() - start_time
    print("\n")

    # Output Summary
    with stats.lock:
        total = stats.total_requests
        success = stats.success_count
        errors = stats.server_error_count
        slow = stats.slow_requests_count
        err_pct = (errors / total * 100.0) if total > 0 else 0.0
        avg_lat = (sum(stats.latencies) / len(stats.latencies)) if stats.latencies else 0.0

    print(f"{CLR_CYAN}{CLR_BOLD}----------------------------------------------------------------------{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  📊 TRAFFIC GENERATION SUMMARY{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}----------------------------------------------------------------------{CLR_RESET}")
    print(f"  Total Requests Executed : {CLR_WHITE}{total}{CLR_RESET}")
    print(f"  Successful (2xx)        : {CLR_GREEN}{success}{CLR_RESET}")
    print(f"  Server Errors (5xx)     : {CLR_RED if errors > 0 else CLR_GREEN}{errors} ({err_pct:.1f}%){CLR_RESET}")
    print(f"  Slow Requests (>500ms)  : {CLR_YELLOW}{slow}{CLR_RESET}")
    print(f"  Average Throughput      : {CLR_WHITE}{total / elapsed:.1f} req/s{CLR_RESET}")
    print(f"  Average Latency         : {CLR_WHITE}{avg_lat * 1000:.2f} ms{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")


def main():
    parser = argparse.ArgumentParser(
        description="Synthetic Traffic & Load Generator for RED and USE Metrics",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--url", default="http://localhost:8000", help="Base URL of instrumented microservice")
    parser.add_argument(
        "--scenario",
        choices=["all", "steady", "latency-spike", "error-burst", "queue-saturation", "resource-errors"],
        default="all",
        help="Traffic generation scenario to run",
    )
    parser.add_argument("--duration", type=int, default=20, help="Duration in seconds")
    parser.add_argument("--concurrency", type=int, default=6, help="Number of concurrent worker threads")
    args = parser.parse_args()

    # Pre-flight check
    try:
        with urllib.request.urlopen(f"{args.url}/healthz", timeout=3.0) as resp:
            if resp.status != 200:
                print(f"{CLR_RED}Error: Service at {args.url}/healthz returned HTTP {resp.status}{CLR_RESET}", file=sys.stderr)
                sys.exit(1)
    except Exception as err:
        print(f"{CLR_RED}Error: Cannot connect to {args.url}: {err}{CLR_RESET}", file=sys.stderr)
        sys.exit(1)

    run_traffic_simulation(
        base_url=args.url.rstrip("/"),
        scenario=args.scenario,
        duration_s=args.duration,
        concurrency=args.concurrency,
    )


if __name__ == "__main__":
    main()
