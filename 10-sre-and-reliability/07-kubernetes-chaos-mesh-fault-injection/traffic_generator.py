#!/usr/bin/env python3
"""
traffic_generator.py - Kubernetes Chaos Traffic Runner & SLO Monitor
====================================================================
Generates continuous HTTP traffic against the target multi-replica
microservice, measures real-time availability (% of 2xx responses) and
latency percentiles (p50, p95, p99), monitors replica load distribution,
and generates structured Chaos Experiment reports.
"""

import argparse
import concurrent.futures
import json
import logging
import math
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ANSI Terminal Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"


class RequestMetrics:
    """Thread-safe telemetry accumulator for chaos experiment load tests."""

    def __init__(self):
        self._lock = threading.Lock()
        self.total = 0
        self.success = 0
        self.failed = 0
        self.latencies_ms: List[float] = []
        self.status_codes: Dict[int, int] = {}
        self.errors: Dict[str, int] = {}
        self.pod_distribution: Dict[str, int] = {}

    def record(
        self,
        success: bool,
        latency_ms: float,
        status_code: int,
        pod_name: Optional[str] = None,
        error_msg: Optional[str] = None,
    ) -> None:
        with self._lock:
            self.total += 1
            if success:
                self.success += 1
            else:
                self.failed += 1

            self.latencies_ms.append(latency_ms)

            if status_code > 0:
                self.status_codes[status_code] = self.status_codes.get(status_code, 0) + 1

            if pod_name:
                self.pod_distribution[pod_name] = self.pod_distribution.get(pod_name, 0) + 1

            if error_msg:
                self.errors[error_msg] = self.errors.get(error_msg, 0) + 1

    def calculate_summary(self) -> Dict[str, Any]:
        with self._lock:
            total = self.total
            success = self.success
            failed = self.failed
            lats = sorted(self.latencies_ms)
            availability = (success / total * 100.0) if total > 0 else 0.0

            def percentile(p: float) -> float:
                if not lats:
                    return 0.0
                k = (len(lats) - 1) * (p / 100.0)
                f = math.floor(k)
                c = math.ceil(k)
                if f == c:
                    return lats[int(k)]
                return lats[int(f)] * (c - k) + lats[int(c)] * (k - f)

            return {
                "total_requests": total,
                "successful_requests": success,
                "failed_requests": failed,
                "availability_pct": round(availability, 3),
                "latency_stats_ms": {
                    "min": round(min(lats), 2) if lats else 0.0,
                    "max": round(max(lats), 2) if lats else 0.0,
                    "mean": round(sum(lats) / len(lats), 2) if lats else 0.0,
                    "p50": round(percentile(50), 2),
                    "p95": round(percentile(95), 2),
                    "p99": round(percentile(99), 2),
                },
                "status_codes": dict(sorted(self.status_codes.items())),
                "pod_distribution": dict(sorted(self.pod_distribution.items())),
                "error_breakdown": dict(sorted(self.errors.items())),
            }


def send_http_request(url: str, timeout: float = 3.0, retries: int = 1) -> Tuple[bool, float, int, Optional[str], Optional[str]]:
    """
    Sends a single HTTP POST request with automatic retry on transient gateway glitches.
    """
    t0 = time.time()
    req = urllib.request.Request(
        url,
        data=b'{"action":"checkout_test"}',
        headers={"Content-Type": "application/json", "User-Agent": "Chaos-Load-Runner/1.0"},
        method="POST",
    )

    last_code = 0
    last_err = None

    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                status_code = response.getcode()
                latency_ms = (time.time() - t0) * 1000.0
                pod_name = response.headers.get("X-Pod-Name")
                raw_body = response.read().decode("utf-8")

                if not pod_name:
                    try:
                        body_json = json.loads(raw_body)
                        pod_name = body_json.get("pod_name") or body_json.get("pod")
                    except Exception:
                        pass

                is_success = 200 <= status_code < 400
                return is_success, latency_ms, status_code, pod_name, None

        except urllib.error.HTTPError as he:
            last_code = he.code
            last_err = f"HTTP_{he.code}"
            if he.code in (502, 503, 504) and attempt < retries:
                time.sleep(0.05)
                continue
            latency_ms = (time.time() - t0) * 1000.0
            return False, latency_ms, he.code, None, last_err

        except urllib.error.URLError as ue:
            last_err = f"URLError_{ue.reason}"
            if attempt < retries:
                time.sleep(0.05)
                continue
            latency_ms = (time.time() - t0) * 1000.0
            return False, latency_ms, 0, None, last_err

        except TimeoutError:
            latency_ms = (time.time() - t0) * 1000.0
            return False, latency_ms, 0, None, "TimeoutError"

        except Exception as e:
            latency_ms = (time.time() - t0) * 1000.0
            return False, latency_ms, 0, None, type(e).__name__

    latency_ms = (time.time() - t0) * 1000.0
    return False, latency_ms, last_code, None, last_err


def run_traffic_load(
    url: str,
    duration_sec: int = 10,
    target_rps: int = 25,
    experiment_name: str = "Chaos Experiment",
    min_availability: float = 99.0,
) -> Dict[str, Any]:
    """
    Generates rate-limited traffic across thread pool and evaluates SLOs.
    """
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  🧪 RUNNING: {CLR_BOLD}{experiment_name}{CLR_RESET}")
    print(f"{CLR_CYAN}======================================================================{CLR_RESET}")
    print(f"  Target URL      : {url}")
    print(f"  Duration        : {duration_sec} seconds")
    print(f"  Target Load     : {target_rps} RPS")
    print(f"  Availability SLO: >= {min_availability}%\n")

    metrics = RequestMetrics()
    start_time = time.time()
    end_time = start_time + duration_sec

    interval = 1.0 / target_rps
    max_workers = min(50, target_rps * 2)

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures: List[concurrent.futures.Future] = []

        while time.time() < end_time:
            loop_start = time.time()
            future = executor.submit(send_http_request, url)
            futures.append(future)

            elapsed = time.time() - loop_start
            sleep_time = interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)

        # Await completion of all in-flight requests
        for future in concurrent.futures.as_completed(futures):
            success, latency_ms, code, pod_name, err = future.result()
            metrics.record(success, latency_ms, code, pod_name, err)

    summary = metrics.calculate_summary()
    summary["experiment_name"] = experiment_name
    summary["duration_sec"] = duration_sec
    summary["target_rps"] = target_rps
    summary["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    passed = summary["availability_pct"] >= min_availability
    summary["status"] = "PASSED" if passed else "FAILED"

    # Display Results
    status_tag = f"{CLR_GREEN}[PASS]{CLR_RESET}" if passed else f"{CLR_RED}[FAIL]{CLR_RESET}"
    print(f"  {status_tag} Availability: {CLR_BOLD}{summary['availability_pct']}%{CLR_RESET} (SLO: {min_availability}%)")
    print(f"         Total: {summary['total_requests']} | Success: {summary['successful_requests']} | Failed: {summary['failed_requests']}")
    lat = summary["latency_stats_ms"]
    print(f"         Latency (ms): p50={lat['p50']} | p95={lat['p95']} | p99={lat['p99']} | max={lat['max']}")
    if summary["pod_distribution"]:
        print(f"         Replicas Hit: {summary['pod_distribution']}")
    if summary["error_breakdown"]:
        print(f"         Errors: {summary['error_breakdown']}")

    return summary


def append_to_reports(summary: Dict[str, Any]) -> None:
    """Appends experiment results to JSON and Markdown reports."""
    # 1. JSON Report
    json_path = os.path.join(SCRIPT_DIR, "chaos_report.json")
    all_reports = []
    if os.path.exists(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                all_reports = json.load(f)
        except Exception:
            all_reports = []

    all_reports.append(summary)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(all_reports, f, indent=2)

    # 2. Markdown Report
    md_path = os.path.join(SCRIPT_DIR, "chaos_report.md")
    write_header = not os.path.exists(md_path)
    with open(md_path, "a" if not write_header else "w", encoding="utf-8") as f:
        if write_header:
            f.write("# Kubernetes Chaos Mesh Fault Injection - Report\n\n")
            f.write("| Timestamp | Experiment Name | Availability (%) | p95 Latency (ms) | Replicas Active | Status |\n")
            f.write("|---|---|---|---|---|---|\n")

        badge = "✅ PASS" if summary["status"] == "PASSED" else "❌ FAIL"
        replicas_count = len(summary["pod_distribution"])
        f.write(
            f"| `{summary['timestamp']}` | **{summary['experiment_name']}** | `{summary['availability_pct']}%` | "
            f"`{summary['latency_stats_ms']['p95']}ms` | `{replicas_count}` pods | {badge} |\n"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Chaos Traffic Generator & SLO Availability Validator")
    parser.add_argument("--url", type=str, default="http://localhost:8088/api/v1/checkout", help="Target microservice URL")
    parser.add_argument("--duration", type=int, default=10, help="Duration in seconds")
    parser.add_argument("--rps", type=int, default=25, help="Requests per second")
    parser.add_argument("--name", type=str, default="Chaos Experiment", help="Experiment name")
    parser.add_argument("--min-availability", type=float, default=99.0, help="Minimum availability SLO percentage")
    args = parser.parse_args()

    summary = run_traffic_load(
        url=args.url,
        duration_sec=args.duration,
        target_rps=args.rps,
        experiment_name=args.name,
        min_availability=args.min_availability,
    )
    append_to_reports(summary)

    if summary["status"] != "PASSED":
        sys.exit(1)


if __name__ == "__main__":
    main()
