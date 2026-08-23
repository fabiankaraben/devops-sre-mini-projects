#!/usr/bin/env python3
"""
chaos_load_runner.py - Continuous Traffic & Steady-State Availability Monitor
=============================================================================
Generates steady transactions against the API Gateway during chaos experiments,
measures availability percentage, latency percentiles, and automatic failovers,
and exports comprehensive SRE Chaos Experiment Reports (Markdown/JSON).
"""

import argparse
import json
import logging
import math
import os
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("chaos_load_runner")

DEFAULT_GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://localhost:8080")


class ChaosMetricsCollector:
    """Thread-safe telemetry collector for active chaos testing runs."""

    def __init__(self, experiment_name: str, duration_sec: int, target_rps: int):
        self.experiment_name = experiment_name
        self.duration_sec = duration_sec
        self.target_rps = target_rps
        self._lock = threading.RLock()

        self.total_requests = 0
        self.success_count = 0
        self.fail_count = 0
        self.failover_count = 0
        self.latencies_ms: List[float] = []
        self.replica_counts: Dict[str, int] = {}
        self.start_time = 0.0
        self.end_time = 0.0

    def record(self, success: bool, duration_ms: float, replica: str, failover: bool):
        with self._lock:
            self.total_requests += 1
            self.latencies_ms.append(duration_ms)
            if success:
                self.success_count += 1
            else:
                self.fail_count += 1
            if failover:
                self.failover_count += 1
            if replica:
                self.replica_counts[replica] = self.replica_counts.get(replica, 0) + 1

    def calculate_percentiles(self) -> Dict[str, float]:
        with self._lock:
            if not self.latencies_ms:
                return {"p50": 0.0, "p90": 0.0, "p95": 0.0, "p99": 0.0, "avg": 0.0, "max": 0.0, "min": 0.0}
            sorted_l = sorted(self.latencies_ms)
            n = len(sorted_l)

            def p(pct: float) -> float:
                k = (n - 1) * (pct / 100.0)
                f = math.floor(k)
                c = math.ceil(k)
                if f == c:
                    return sorted_l[int(k)]
                return sorted_l[int(f)] * (c - k) + sorted_l[int(c)] * (k - f)

            return {
                "min": round(sorted_l[0], 2),
                "avg": round(sum(sorted_l) / n, 2),
                "p50": round(p(50), 2),
                "p90": round(p(90), 2),
                "p95": round(p(95), 2),
                "p99": round(p(99), 2),
                "max": round(sorted_l[-1], 2),
            }

    def get_summary(self) -> Dict[str, Any]:
        with self._lock:
            elapsed = max(0.001, self.end_time - self.start_time)
            avail_pct = round((self.success_count / max(1, self.total_requests)) * 100.0, 2)
            actual_rps = round(self.total_requests / elapsed, 1)
            pcts = self.calculate_percentiles()

            return {
                "experiment_name": self.experiment_name,
                "duration_seconds": round(elapsed, 1),
                "target_rps": self.target_rps,
                "actual_rps": actual_rps,
                "total_requests": self.total_requests,
                "successful_requests": self.success_count,
                "failed_requests": self.fail_count,
                "availability_percent": avail_pct,
                "failover_requests_count": self.failover_count,
                "replica_traffic_distribution": dict(self.replica_counts),
                "latencies_ms": pcts,
            }


def worker_loop(collector: ChaosMetricsCollector, gateway_url: str, stop_event: threading.Event, delay_between_req: float):
    endpoint = f"{gateway_url.rstrip('/')}/api/v1/checkout"
    headers = {"Content-Type": "application/json", "User-Agent": "ChaosLoadRunner/1.0"}

    while not stop_event.is_set():
        order_id = f"ord_chaos_{int(time.time() * 1000)}_{random.randint(100, 999)}"
        payload = json.dumps({"order_id": order_id, "amount": 89.99, "user_id": "usr_chaos_tester"}).encode("utf-8")

        start = time.time()
        success = False
        replica = ""
        failover = False

        try:
            req = urllib.request.Request(endpoint, data=payload, headers=headers)
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                duration_ms = (time.time() - start) * 1000.0
                if resp.status == 200:
                    success = True
                    body = json.loads(resp.read().decode("utf-8"))
                    telemetry = body.get("gateway_telemetry", {})
                    replica = telemetry.get("served_by_replica", "unknown")
                    failover = telemetry.get("failover_required", False)
        except Exception:
            duration_ms = (time.time() - start) * 1000.0
            success = False

        collector.record(success, duration_ms, replica, failover)
        if delay_between_req > 0:
            stop_event.wait(delay_between_req)


def run_load_experiment(
    experiment_name: str,
    gateway_url: str,
    duration_sec: int,
    target_rps: int,
    concurrency: int = 4,
) -> ChaosMetricsCollector:
    collector = ChaosMetricsCollector(experiment_name, duration_sec, target_rps)
    stop_event = threading.Event()

    delay_per_thread = concurrency / max(1, target_rps)
    threads = []

    collector.start_time = time.time()
    for _ in range(concurrency):
        t = threading.Thread(
            target=worker_loop,
            args=(collector, gateway_url, stop_event, delay_per_thread),
            daemon=True,
        )
        t.start()
        threads.append(t)

    # Display progress updates
    start_ts = time.time()
    while time.time() - start_ts < duration_sec:
        elapsed = time.time() - start_ts
        with collector._lock:
            reqs = collector.total_requests
            succ = collector.success_count
            fails = collector.fail_count
            fails_over = collector.failover_count
            pct = (succ / max(1, reqs)) * 100.0
        sys.stdout.write(
            f"\r⏱️  [{elapsed:4.1f}s / {duration_sec}s] Requests: {reqs:4d} | Success: {succ:4d} | "
            f"Fails: {fails:2d} | Failovers: {fails_over:3d} | Availability: {pct:6.2f}%"
        )
        sys.stdout.flush()
        stop_event.wait(0.2)

    stop_event.set()
    collector.end_time = time.time()
    sys.stdout.write("\n")
    sys.stdout.flush()
    return collector


def export_reports(summary: Dict[str, Any], json_path: str, md_path: str):
    # JSON export
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    # Markdown export
    dist_rows = "\n".join([f"| `{k}` | **{v}** requests |" for k, v in summary["replica_traffic_distribution"].items()])
    lat = summary["latencies_ms"]

    md_content = f"""# SRE Chaos Engineering Experiment Report

## 🧪 Experiment: {summary['experiment_name']}

- **Execution Duration**: {summary['duration_seconds']} seconds
- **Traffic Load**: {summary['actual_rps']} req/s (Target: {summary['target_rps']} req/s)
- **Total Requests Processed**: {summary['total_requests']}
- **Steady-State Availability**: **`{summary['availability_percent']}%`**
- **Successful Requests**: `{summary['successful_requests']}`
- **Failed Requests**: `{summary['failed_requests']}`
- **Automatic Failovers Triggered**: `{summary['failover_requests_count']}`

---

## 📊 Latency Percentiles (p50 / p90 / p95 / p99)

| Metric | Measured Duration |
| :--- | :--- |
| **Minimum Latency** | `{lat['min']} ms` |
| **Average Latency** | `{lat['avg']} ms` |
| **p50 (Median)** | `{lat['p50']} ms` |
| **p90** | `{lat['p90']} ms` |
| **p95 (SLO Target)** | **`{lat['p95']} ms`** |
| **p99 (Tail Latency)**| `{lat['p99']} ms` |
| **Maximum Latency** | `{lat['max']} ms` |

---

## 🔀 Replica Traffic Distribution

| Downstream Replica | Handled Volume |
| :--- | :--- |
{dist_rows if dist_rows else "| *None* | 0 |"}

---
*Report auto-generated by `chaos_load_runner.py`.*
"""
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(md_content)
    logger.info("Saved reports to %s and %s", json_path, md_path)


def main():
    parser = argparse.ArgumentParser(description="Chaos Engineering Traffic & Availability Monitor")
    parser.add_argument("--name", "-n", type=str, default="Baseline Traffic Steady State", help="Experiment name")
    parser.add_argument("--url", "-u", type=str, default=DEFAULT_GATEWAY_URL, help="Gateway URL")
    parser.add_argument("--duration", "-d", type=int, default=10, help="Test duration in seconds")
    parser.add_argument("--rps", "-r", type=int, default=25, help="Target requests per second")
    parser.add_argument("--concurrency", "-c", type=int, default=4, help="Client concurrency threads")
    parser.add_argument("--min-availability", type=float, default=99.0, help="Minimum acceptable availability percentage")
    parser.add_argument("--json-out", type=str, default="chaos_report.json", help="Path to JSON output")
    parser.add_argument("--md-out", type=str, default="chaos_report.md", help="Path to Markdown output")
    args = parser.parse_args()

    print("\n" + "=" * 75)
    print(f"  🧪 SRE CHAOS EXPERIMENT LOAD RUNNER: {args.name}")
    print("=" * 75)
    print(f"  Target Gateway:  {args.url}")
    print(f"  Duration:        {args.duration}s")
    print(f"  Target Load:     {args.rps} RPS (Concurrency: {args.concurrency})")
    print(f"  SLO Threshold:   >= {args.min_availability}% Availability\n")

    collector = run_load_experiment(args.name, args.url, args.duration, args.rps, args.concurrency)
    summary = collector.get_summary()

    export_reports(summary, args.json_out, args.md_out)

    print("\n" + "=" * 75)
    print("  📊 EXPERIMENT SUMMARY RESULTS")
    print("=" * 75)
    print(f"  Processed Requests:   {summary['total_requests']}")
    print(f"  Successful:           {summary['successful_requests']}")
    print(f"  Failed:               {summary['failed_requests']}")
    print(f"  Failovers Triggered:  {summary['failover_requests_count']}")
    print(f"  Availability:         {summary['availability_percent']}%")
    print(f"  Latency p95:          {summary['latencies_ms']['p95']} ms")
    print(f"  Traffic Distribution: {summary['replica_traffic_distribution']}")
    print("=" * 75)

    if summary["availability_percent"] >= args.min_availability:
        print(f"\n🎉 [PASS] Experiment passed with {summary['availability_percent']}% availability (SLO: >={args.min_availability}%).\n")
        sys.exit(0)
    else:
        print(f"\n❌ [FAIL] Availability dropped to {summary['availability_percent']}% (Below SLO threshold of {args.min_availability}%).\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
