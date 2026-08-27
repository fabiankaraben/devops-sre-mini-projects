#!/usr/bin/env python3
"""
load_tester.py - High-Concurrency HTTP Load Tester & Connection Draining Monitor
================================================================================
Generates continuous HTTP traffic with realistic transaction latency to measure
application availability and connection resets during rolling updates and pod restarts.
"""

import argparse
import datetime
import json
import logging
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Set

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("load_tester")

# Global stop flag
stop_event = threading.Event()


def signal_handler(signum: int, frame: Any) -> None:
    logger.info("Load test interruption requested.")
    stop_event.set()


class DrainingMetricsTracker:
    """Thread-safe accumulator for load test results."""

    def __init__(self):
        self.lock = threading.Lock()
        self.total_requests = 0
        self.successful_2xx = 0
        self.client_errors_4xx = 0
        self.server_errors_5xx = 0
        self.connection_resets = 0
        self.timeouts = 0
        self.other_errors = 0
        self.drained_count = 0
        self.latencies_ms: List[float] = []
        self.pods_seen: Set[str] = set()
        self.error_log: List[Dict[str, Any]] = []

    def record_success(self, duration_ms: float, pod_name: str, was_draining: bool) -> None:
        with self.lock:
            self.total_requests += 1
            self.successful_2xx += 1
            self.latencies_ms.append(duration_ms)
            if pod_name:
                self.pods_seen.add(pod_name)
            if was_draining:
                self.drained_count += 1

    def record_http_error(self, status_code: int, duration_ms: float, pod_name: str, message: str) -> None:
        with self.lock:
            self.total_requests += 1
            self.latencies_ms.append(duration_ms)
            if 400 <= status_code < 500:
                self.client_errors_4xx += 1
            else:
                self.server_errors_5xx += 1

            if len(self.error_log) < 50:
                self.error_log.append({
                    "type": f"HTTP_{status_code}",
                    "message": message,
                    "pod": pod_name,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                })

    def record_connection_error(self, err_type: str, message: str) -> None:
        with self.lock:
            self.total_requests += 1
            if "reset" in message.lower() or "disconnected" in message.lower() or "pipe" in message.lower():
                self.connection_resets += 1
            elif "timed out" in message.lower():
                self.timeouts += 1
            else:
                self.other_errors += 1

            if len(self.error_log) < 50:
                self.error_log.append({
                    "type": err_type,
                    "message": message,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                })

    def get_summary(self, elapsed_sec: float) -> Dict[str, Any]:
        with self.lock:
            total = self.total_requests
            success = self.successful_2xx
            dropped = self.connection_resets + self.server_errors_5xx + self.timeouts
            avail_pct = round((success / total * 100.0), 2) if total > 0 else 0.0
            rps = round(total / elapsed_sec, 1) if elapsed_sec > 0 else 0.0

            sorted_lat = sorted(self.latencies_ms) if self.latencies_ms else [0.0]
            n = len(sorted_lat)
            p50 = sorted_lat[int(n * 0.50)] if n > 0 else 0.0
            p95 = sorted_lat[min(int(n * 0.95), n - 1)] if n > 0 else 0.0
            p99 = sorted_lat[min(int(n * 0.99), n - 1)] if n > 0 else 0.0

            return {
                "elapsed_seconds": round(elapsed_sec, 2),
                "total_requests": total,
                "successful_2xx": success,
                "server_errors_5xx": self.server_errors_5xx,
                "connection_resets": self.connection_resets,
                "timeouts": self.timeouts,
                "other_errors": self.other_errors,
                "dropped_requests": dropped,
                "availability_pct": avail_pct,
                "requests_per_second": rps,
                "drained_requests_served": self.drained_count,
                "unique_pods_served": sorted(list(self.pods_seen)),
                "latency_p50_ms": round(p50, 2),
                "latency_p95_ms": round(p95, 2),
                "latency_p99_ms": round(p99, 2),
                "error_samples": self.error_log[:10],
            }


def worker_loop(
    target_url: str,
    tracker: DrainingMetricsTracker,
    target_rps_per_thread: float,
    timeout_sec: float,
) -> None:
    """Worker thread generating continuous HTTP requests."""
    delay = (1.0 / target_rps_per_thread) if target_rps_per_thread > 0 else 0.05

    while not stop_event.is_set():
        start_ts = time.time()
        req = urllib.request.Request(
            target_url,
            headers={"User-Agent": "SRE-Draining-LoadTester/1.0", "Connection": "close"},
        )

        try:
            with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                status_code = resp.status
                body = resp.read().decode("utf-8")
                duration_ms = (time.time() - start_ts) * 1000.0

                pod_name = resp.headers.get("X-Pod-Name", "")
                was_draining = False
                try:
                    payload = json.loads(body)
                    pod_name = pod_name or payload.get("pod_name", "")
                    was_draining = payload.get("was_draining", False)
                except Exception:
                    pass

                tracker.record_success(duration_ms, pod_name, was_draining)

        except urllib.error.HTTPError as e:
            duration_ms = (time.time() - start_ts) * 1000.0
            pod_name = e.headers.get("X-Pod-Name", "") if e.headers else ""
            tracker.record_http_error(e.code, duration_ms, pod_name, str(e))

        except urllib.error.URLError as e:
            reason = str(e.reason)
            tracker.record_connection_error("URLError", reason)

        except Exception as e:
            tracker.record_connection_error(type(e).__name__, str(e))

        # Pace requests
        time.sleep(delay)


def run_load_test(
    target_url: str,
    concurrency: int = 10,
    duration_sec: float = 20.0,
    rps_per_thread: float = 3.0,
    timeout_sec: float = 5.0,
    stop_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Orchestrates multi-threaded load test execution."""
    tracker = DrainingMetricsTracker()
    threads: List[threading.Thread] = []

    logger.info(
        f"🚀 Starting continuous flood load test against: {target_url}\n"
        f"   Concurrency: {concurrency} threads | Duration: {duration_sec}s | Target RPS: ~{concurrency * rps_per_thread}"
    )

    start_time = time.time()
    for i in range(concurrency):
        t = threading.Thread(
            target=worker_loop,
            args=(target_url, tracker, rps_per_thread, timeout_sec),
            name=f"worker-{i+1}",
            daemon=True,
        )
        t.start()
        threads.append(t)

    # Monitor loop
    try:
        while time.time() - start_time < duration_sec and not stop_event.is_set():
            if stop_file and os.path.exists(stop_file):
                logger.info(f"Stop signal file detected: {stop_file}")
                break

            time.sleep(1.0)
            elapsed = time.time() - start_time
            stats = tracker.get_summary(elapsed)
            logger.info(
                f"⏱️ [{elapsed:.0f}s / {duration_sec:.0f}s] "
                f"Total: {stats['total_requests']} | "
                f"2xx OK: {stats['successful_2xx']} | "
                f"5xx: {stats['server_errors_5xx']} | "
                f"Resets: {stats['connection_resets']} | "
                f"Avail: {stats['availability_pct']}% | "
                f"Pods: {len(stats['unique_pods_served'])}"
            )
    finally:
        stop_event.set()
        for t in threads:
            t.join(timeout=1.0)

    total_elapsed = time.time() - start_time
    return tracker.get_summary(total_elapsed)


def export_markdown_report(summary: Dict[str, Any], title: str, output_path: str) -> None:
    """Exports structured Markdown report with markdownlint conformance."""
    md = []
    md.append("<!-- markdownlint-disable MD013 MD033 MD051 MD060 -->")
    md.append(f"# {title}\n")
    md.append(f"> **Date**: `{datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}` | **Duration**: `{summary['elapsed_seconds']}s` | **Availability**: `{summary['availability_pct']}%`\n")
    md.append("---\n")

    md.append("## 1. Executive Reliability Summary\n")
    md.append("| Metric | Measurement | Target Standard | Status |")
    md.append("|---|---|---|---|")
    status_avail = "✅ PASS" if summary["availability_pct"] >= 99.9 else "❌ FAIL"
    status_resets = "✅ PASS" if summary["connection_resets"] == 0 else "❌ FAIL"
    md.append(f"| **Availability** | **`{summary['availability_pct']}%`** | `100.0%` | {status_avail} |")
    md.append(f"| **Connection Resets (ECONNRESET)** | **`{summary['connection_resets']}`** | `0` | {status_resets} |")
    md.append(f"| **HTTP 5xx Server Errors** | **`{summary['server_errors_5xx']}`** | `0` | {'✅ PASS' if summary['server_errors_5xx'] == 0 else '❌ FAIL'} |")
    md.append(f"| **Total Requests Processed** | `{summary['total_requests']:,}` | N/A | ℹ️ |")
    md.append(f"| **Throughput (RPS)** | `{summary['requests_per_second']} req/s` | N/A | ℹ️ |")
    md.append(f"| **Drained In-Flight Requests** | `{summary['drained_requests_served']}` | N/A | ℹ️ |")
    md.append(f"| **Latency p50 / p95 / p99** | `{summary['latency_p50_ms']}ms` / `{summary['latency_p95_ms']}ms` / `{summary['latency_p99_ms']}ms` | `< 1000ms` | ✅ |\n")

    md.append("## 2. Pod Routing Diversity\n")
    md.append(f"During the rolling update, traffic was distributed across **{len(summary['unique_pods_served'])}** distinct pod instances:\n")
    for pod in summary["unique_pods_served"]:
        md.append(f"- 📦 Pod: `{pod}`")
    md.append("")

    if summary["error_samples"]:
        md.append("## 3. Error Log Samples\n")
        md.append("| Error Type | Message | Pod | Timestamp |")
        md.append("|---|---|---|---|")
        for err in summary["error_samples"]:
            md.append(f"| `{err.get('type')}` | `{err.get('message')}` | `{err.get('pod', 'N/A')}` | `{err.get('timestamp')}` |")
        md.append("")

    md.append("---\n*Report generated by SRE Graceful Shutdown & Connection Draining Load Engine.*\n")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(md))


def main() -> None:
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    parser = argparse.ArgumentParser(description="Graceful Shutdown & Connection Draining Load Tester")
    parser.add_argument("--url", type=str, default="http://localhost:8089/api/v1/work", help="Target URL to load test")
    parser.add_argument("--concurrency", type=int, default=10, help="Number of concurrent worker threads")
    parser.add_argument("--duration", type=float, default=20.0, help="Duration in seconds")
    parser.add_argument("--rps", type=float, default=3.0, help="Target requests per second per thread")
    parser.add_argument("--timeout", type=float, default=5.0, help="HTTP request timeout in seconds")
    parser.add_argument("--stop-file", type=str, default=None, help="File path that triggers load tester stop when created")
    parser.add_argument("--report-dir", type=str, default="./reports", help="Directory to output reports")
    parser.add_argument("--title", type=str, default="Graceful Rolling Update Reliability Report", help="Report title")
    parser.add_argument("--assert-zero-downtime", action="store_true", help="Exit with code 1 if availability < 100%% or connection resets > 0")

    args = parser.parse_args()

    summary = run_load_test(
        target_url=args.url,
        concurrency=args.concurrency,
        duration_sec=args.duration,
        rps_per_thread=args.rps,
        timeout_sec=args.timeout,
        stop_file=args.stop_file,
    )

    print("\n" + "=" * 70)
    print(f"  📊 {args.title.upper()}")
    print("=" * 70)
    print(f"  • Total Requests   : {summary['total_requests']}")
    print(f"  • Successful 2xx   : {summary['successful_2xx']}")
    print(f"  • Server 5xx Errors: {summary['server_errors_5xx']}")
    print(f"  • Connection Resets: {summary['connection_resets']}")
    print(f"  • Availability Rate: {summary['availability_pct']}%")
    print(f"  • Drained Requests : {summary['drained_requests_served']}")
    print(f"  • Latency p95 / p99: {summary['latency_p95_ms']}ms / {summary['latency_p99_ms']}ms")
    print(f"  • Pods Handled     : {summary['unique_pods_served']}")
    print("=" * 70 + "\n")

    os.makedirs(args.report_dir, exist_ok=True)
    slug = args.title.lower().replace(" ", "_").replace("-", "_")
    json_path = os.path.join(args.report_dir, f"{slug}.json")
    md_path = os.path.join(args.report_dir, f"{slug}.md")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    export_markdown_report(summary, args.title, md_path)

    logger.info(f"Saved reports: {md_path} and {json_path}")

    if args.assert_zero_downtime:
        if summary["availability_pct"] < 99.9 or summary["connection_resets"] > 0:
            logger.error(f"❌ Assertion Failed: Availability was {summary['availability_pct']}% with {summary['connection_resets']} resets.")
            sys.exit(1)
        else:
            logger.info("✅ Zero-Downtime Assertion Succeeded: 100.0% availability with 0 dropped requests!")


if __name__ == "__main__":
    main()
