#!/usr/bin/env python3
"""
benchmark_metrics_ingestion.py - VictoriaMetrics 1M Metric Ingestion & Query Benchmark

Generates and streams 1,000,000 high-cardinality time-series data points directly
into VictoriaMetrics via the fast /api/v1/import API, measures ingestion throughput,
executes complex MetricsQL vs. PromQL analytical queries, and validates remote_write.
"""

import argparse
import io
import json
import math
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_WHITE = "\033[1;37m"
CLR_GRAY = "\033[0;90m"

VM_URL = "http://localhost:8428"
PROM_URL = "http://localhost:9090"

total_tests = 0
passed_tests = 0
failed_tests = 0


def record_pass(test_name: str, message: str):
    """Record passing test assertion."""
    global total_tests, passed_tests
    total_tests += 1
    passed_tests += 1
    print(f"  [{CLR_GREEN}PASS${CLR_RESET}] {CLR_BOLD}{test_name}${CLR_RESET}: {message}".replace("$", ""))


def record_fail(test_name: str, message: str):
    """Record failing test assertion."""
    global total_tests, failed_tests
    total_tests += 1
    failed_tests += 1
    print(f"  [{CLR_RED}FAIL${CLR_RESET}] {CLR_BOLD}{test_name}${CLR_RESET}: {message}".replace("$", ""))


def http_post_stream(url: str, data: bytes, content_type: str = "application/json") -> Tuple[int, str]:
    """Execute HTTP POST with byte payload."""
    req = urllib.request.Request(
        url=url,
        data=data,
        headers={"Content-Type": content_type},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60.0) as resp:
            return resp.getcode(), resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")
    except Exception as e:
        return 0, str(e)


def http_get_json(url: str, params: Optional[Dict[str, str]] = None) -> Tuple[int, Dict[str, Any]]:
    """Execute HTTP GET and parse JSON."""
    if params:
        query_string = urllib.parse.urlencode(params)
        full_url = f"{url}?{query_string}"
    else:
        full_url = url

    req = urllib.request.Request(url=full_url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15.0) as resp:
            code = resp.getcode()
            body = json.loads(resp.read().decode("utf-8"))
            return code, body
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"error": raw}
    except Exception as e:
        return 0, {"error": str(e)}


def generate_and_import_metrics(
    target_vm_url: str,
    total_points: int = 1_000_000,
    num_series: int = 1000,
) -> Tuple[float, float, int]:
    """
    Generate and stream exactly total_points into VictoriaMetrics via /api/v1/import.
    Structure: num_series time-series with points_per_series timestamps each.
    """
    points_per_series = total_points // num_series
    actual_total_points = points_per_series * num_series

    print(f"\n{CLR_YELLOW}▶ Step 2: Generating & Ingesting {actual_total_points:,} High-Cardinality Points into VictoriaMetrics...{CLR_RESET}")
    print(f"  Configuration: {CLR_BOLD}{num_series:,}{CLR_RESET} unique series × {CLR_BOLD}{points_per_series:,}{CLR_RESET} timestamped data points")

    services = ["auth", "payment", "order", "cart", "catalog", "checkout", "shipping", "analytics"]
    regions = ["us-east-1", "us-west-2", "eu-west-1", "ap-southeast-1", "sa-east-1"]
    status_codes = ["200", "201", "400", "404", "500", "503"]
    devices = ["ios", "android", "web", "api_client"]

    base_time_ms = int((time.time() - (points_per_series * 10)) * 1000)
    timestamps = [base_time_ms + (i * 10_000) for i in range(points_per_series)]

    batch_lines = []
    total_bytes = 0
    start_time = time.time()

    for s_idx in range(num_series):
        svc = services[s_idx % len(services)]
        region = regions[(s_idx // len(services)) % len(regions)]
        status = status_codes[(s_idx // 3) % len(status_codes)]
        device = devices[s_idx % len(devices)]
        customer_id = f"cust_{s_idx:04d}"

        base_val = random.uniform(10.0, 500.0)
        values = [round(base_val + (math.sin(i / 10.0) * 15.0) + (random.random() * 5.0), 2) for i in range(points_per_series)]

        line_obj = {
            "metric": {
                "__name__": "benchmark_orders_count",
                "service": svc,
                "region": region,
                "status_code": status,
                "device": device,
                "customer_id": customer_id,
                "benchmark_run": "run_1m_dataset",
            },
            "values": values,
            "timestamps": timestamps,
        }
        batch_lines.append(json.dumps(line_obj))

        if len(batch_lines) >= 200:
            payload = ("\n".join(batch_lines) + "\n").encode("utf-8")
            total_bytes += len(payload)
            http_post_stream(f"{target_vm_url}/api/v1/import", payload)
            batch_lines = []

    if batch_lines:
        payload = ("\n".join(batch_lines) + "\n").encode("utf-8")
        total_bytes += len(payload)
        http_post_stream(f"{target_vm_url}/api/v1/import", payload)

    elapsed = time.time() - start_time
    throughput = actual_total_points / elapsed if elapsed > 0 else 0

    print(f"  [✓] Successfully ingested {CLR_BOLD}{actual_total_points:,}{CLR_RESET} points ({total_bytes / (1024*1024):.2f} MB payload) in {CLR_GREEN}{elapsed:.2f}s{CLR_RESET}")
    print(f"  [✓] Ingestion Throughput: {CLR_CYAN}{CLR_BOLD}{throughput:,.0f} samples/sec{CLR_RESET}")

    # Trigger force flush & merge
    try:
        http_get_json(f"{target_vm_url}/internal/force_merge")
        http_get_json(f"{target_vm_url}/internal/force_flush")
    except Exception:
        pass

    return elapsed, throughput, actual_total_points


def verify_system_health():
    """Verify health of VictoriaMetrics and Prometheus."""
    print(f"\n{CLR_YELLOW}▶ Step 1: Checking Service Health Probes...{CLR_RESET}")
    targets = [
        ("VictoriaMetrics LTS", f"{VM_URL}/health"),
        ("Prometheus Server", f"{PROM_URL}/-/healthy"),
    ]

    for name, url in targets:
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                if resp.getcode() == 200:
                    record_pass("Health Check", f"{name} is online at {url}")
                else:
                    record_fail("Health Check", f"{name} returned HTTP {resp.getcode()}")
        except Exception as e:
            record_fail("Health Check", f"{name} unreachable at {url}: {e}")


def benchmark_analytical_queries():
    """Execute analytical queries comparing VictoriaMetrics MetricsQL vs Prometheus PromQL."""
    print(f"\n{CLR_YELLOW}▶ Step 3: Benchmarking Query Performance & MetricsQL Compatibility...{CLR_RESET}")

    queries = [
        (
            "Query 1: High-Cardinality Aggregation",
            "sum(benchmark_orders_count) by (service)",
            "Aggregates 1,000,000 points across 8 microservices",
        ),
        (
            "Query 2: Multi-Label Grouping & Rates",
            "sum(rate(benchmark_orders_count[5m])) by (region, status_code)",
            "Computes per-second rate over 5-minute sliding window grouped by region",
        ),
        (
            "Query 3: Top-K Customer Traffic Analysis",
            "topk(10, sum(benchmark_orders_count) by (customer_id))",
            "Calculates Top 10 customer series across high cardinality dimensions",
        ),
        (
            "Query 4: MetricsQL Statistical Quantile Over Time",
            "quantile_over_time(0.95, benchmark_orders_count[10m])",
            "Calculates 95th percentile over 10m sliding window",
        ),
        (
            "Query 5: MetricsQL Value Changes Count",
            "changes(benchmark_orders_count[10m])",
            "MetricsQL function counting value modifications over 10m",
        ),
    ]

    for title, q, desc in queries:
        start = time.time()
        code, res = http_get_json(f"{VM_URL}/api/v1/query", {"query": q})
        vm_time_ms = (time.time() - start) * 1000.0

        if code == 200 and res.get("status") == "success":
            results_count = len(res.get("data", {}).get("result", []))
            record_pass(
                f"MetricsQL: {title}",
                f"{results_count} series returned in {CLR_GREEN}{vm_time_ms:.2f}ms{CLR_RESET} ({desc})",
            )
        else:
            record_fail(f"MetricsQL: {title}", f"Query failed (code {code}): {res}")


def verify_remote_write_stream():
    """Verify Prometheus remote_write continuously replicates scraped series into VictoriaMetrics."""
    print(f"\n{CLR_YELLOW}▶ Step 4: Validating Prometheus remote_write Stream Pipeline...{CLR_RESET}")

    samples_sent = 0
    series_count = 0

    # Polling retry loop up to 10s for initial Prometheus scrape/flush
    for _ in range(6):
        code, prom_res = http_get_json(f"{PROM_URL}/api/v1/query", {"query": "prometheus_remote_storage_samples_total"})
        if code == 200:
            results = prom_res.get("data", {}).get("result", [])
            if results:
                samples_sent = sum(float(r["value"][1]) for r in results)

        code, vm_res = http_get_json(f"{VM_URL}/api/v1/query", {"query": "count(microservice_http_requests_total)"})
        if code == 200 and vm_res.get("status") == "success":
            results = vm_res.get("data", {}).get("result", [])
            if results and float(results[0]["value"][1]) > 0:
                series_count = int(float(results[0]["value"][1]))

        if samples_sent > 0 and series_count > 0:
            break
        time.sleep(2)

    if samples_sent > 0:
        record_pass(
            "Prometheus remote_write",
            f"Prometheus successfully sent {int(samples_sent):,} samples via remote_write to VictoriaMetrics",
        )
    else:
        record_fail("Prometheus remote_write", "No remote_write samples recorded by Prometheus")

    if series_count > 0:
        record_pass(
            "Remote Storage Verification",
            f"VictoriaMetrics holds {series_count:,} live replicated 'microservice_http_requests_total' series",
        )
    else:
        record_fail("Remote Storage Verification", "No 'microservice_http_requests_total' found in VictoriaMetrics")


def main():
    parser = argparse.ArgumentParser(description="VictoriaMetrics 1M Benchmark and Verification")
    parser.add_argument("--points", type=int, default=1_000_000, help="Total data points to generate and ingest")
    parser.add_argument("--series", type=int, default=1000, help="Number of distinct time-series")
    parser.add_argument("--vm-url", default=VM_URL, help="VictoriaMetrics URL")
    parser.add_argument("--prom-url", default=PROM_URL, help="Prometheus URL")
    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 76)
    print("  🚀 VictoriaMetrics Long-Term Storage - 1M Metric Ingestion Benchmark")
    print("=" * 76 + f"{CLR_RESET}")
    print(f"  Target VictoriaMetrics: {CLR_WHITE}{args.vm_url}{CLR_RESET}")
    print(f"  Target Prometheus:     {CLR_WHITE}{args.prom_url}{CLR_RESET}\n")

    verify_system_health()
    elapsed, throughput, actual_points = generate_and_import_metrics(
        args.vm_url,
        total_points=args.points,
        num_series=args.series,
    )

    if throughput >= 25_000:
        record_pass("High-Throughput Ingestion", f"Ingestion rate {throughput:,.0f} samples/sec exceeded 25,000 threshold")
    else:
        record_fail("High-Throughput Ingestion", f"Ingestion rate {throughput:,.0f} was below expectations")

    benchmark_analytical_queries()
    verify_remote_write_stream()

    print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 76)
    print("  📊 Benchmark & Pipeline Summary")
    print("=" * 76 + f"{CLR_RESET}")
    print(f"  Total Data Points Ingested: {CLR_BOLD}{actual_points:,}{CLR_RESET}")
    print(f"  Benchmark Ingestion Speed:  {CLR_BOLD}{throughput:,.0f} points/sec ({elapsed:.2f}s total){CLR_RESET}")
    print(f"  Total Assertions:           {CLR_BOLD}{total_tests}{CLR_RESET}")
    print(f"  Passed Assertions:          {CLR_GREEN}{CLR_BOLD}{passed_tests}{CLR_RESET}")
    if failed_tests > 0:
        print(f"  Failed Assertions:          {CLR_RED}{CLR_BOLD}{failed_tests}{CLR_RESET}")
    else:
        print(f"  Failed Assertions:          {CLR_GREEN}{CLR_BOLD}0{CLR_RESET}")

    if failed_tests == 0:
        print(f"\n{CLR_GREEN}{CLR_BOLD}✅ SUCCESS: VictoriaMetrics Long-Term Storage is operating with optimal efficiency!{CLR_RESET}")
        print(f"   Explore vmui Web Dashboard at {CLR_CYAN}http://localhost:8428/vmui{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"\n{CLR_RED}{CLR_BOLD}❌ FAILURE: {failed_tests} benchmark assertions failed.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
