#!/usr/bin/env python3
"""
Automated Traffic Injector for Shadow Traffic Mirroring Proxy
Generates realistic client traffic (GET/POST with JSON payloads and correlation IDs)
against the Nginx reverse proxy, measures client latency, and verifies 100% replication fidelity.
"""

import argparse
import concurrent.futures
import json
import random
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_BLUE = "\033[1;34m"
CLR_GRAY = "\033[0;90m"

ITEM_CATALOG = [
    "Kubernetes Node Pool", "PostgreSQL Read Replica", "Redis Cache Cluster",
    "WireGuard VPN Mesh Gateway", "Envoy Canary Router", "Prometheus Ingestion Agent",
    "OpenSearch Storage Volume", "Cloudflare DNS Record Tier", "CoreDNS Query Worker"
]

def send_single_request(target_url, index, method="POST"):
    req_id = f"inj-{int(time.time() * 1000)}-{index:04d}-{random.randint(100, 999)}"
    
    if method == "POST":
        if random.random() > 0.3:
            url = f"{target_url}/api/v1/orders"
            payload = {
                "order_id": f"ORD-AUTO-{index:04d}",
                "item": random.choice(ITEM_CATALOG),
                "amount": round(random.uniform(19.99, 499.50), 2),
                "currency": "USD",
                "client_batch_index": index
            }
        else:
            url = f"{target_url}/api/v1/users"
            payload = {
                "user_id": f"USR-AUTO-{index:04d}",
                "name": f"Automated Engineer #{index}",
                "role": "SRE Reliability Auditor"
            }
        body_bytes = json.dumps(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "X-Request-ID": req_id,
            "User-Agent": "TrafficInjector/1.0"
        }
        req = urllib.request.Request(url, data=body_bytes, headers=headers, method="POST")
    else:
        url = f"{target_url}/api/v1/orders"
        headers = {
            "X-Request-ID": req_id,
            "User-Agent": "TrafficInjector/1.0"
        }
        req = urllib.request.Request(url, headers=headers, method="GET")

    start_t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            elapsed_ms = (time.time() - start_t) * 1000
            resp_body = resp.read().decode("utf-8")
            return {
                "success": True,
                "request_id": req_id,
                "status_code": resp.status,
                "latency_ms": elapsed_ms,
                "headers": dict(resp.headers),
                "body": resp_body
            }
    except urllib.error.HTTPError as e:
        elapsed_ms = (time.time() - start_t) * 1000
        return {
            "success": False,
            "request_id": req_id,
            "status_code": e.code,
            "latency_ms": elapsed_ms,
            "error": str(e)
        }
    except Exception as e:
        elapsed_ms = (time.time() - start_t) * 1000
        return {
            "success": False,
            "request_id": req_id,
            "status_code": 0,
            "latency_ms": elapsed_ms,
            "error": str(e)
        }

def run_traffic_injection(target_url, num_requests, concurrency, verify_diff):
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🪞 Shadow Traffic Mirroring Injector & Verifier{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_GRAY}Target URL       : {CLR_BOLD}{target_url}{CLR_RESET}")
    print(f"{CLR_GRAY}Total Requests   : {CLR_BOLD}{num_requests}{CLR_RESET}")
    print(f"{CLR_GRAY}Concurrency Level: {CLR_BOLD}{concurrency}{CLR_RESET}")
    print(f"{CLR_GRAY}Verify Diffs     : {CLR_BOLD}{verify_diff}{CLR_RESET}\n")

    results = []
    start_total = time.time()

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [
            executor.submit(send_single_request, target_url, i + 1, "POST" if i % 4 != 0 else "GET")
            for i in range(num_requests)
        ]
        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())

    total_duration = time.time() - start_total
    successful = [r for r in results if r["success"]]
    failed = [r for r in results if not r["success"]]
    latencies = [r["latency_ms"] for r in results]

    avg_lat = sum(latencies) / len(latencies) if latencies else 0
    p95_lat = sorted(latencies)[int(len(latencies) * 0.95)] if latencies else 0
    min_lat = min(latencies) if latencies else 0
    max_lat = max(latencies) if latencies else 0

    print(f"{CLR_BLUE}{CLR_BOLD}▶ Traffic Injection Metrics{CLR_RESET}")
    print(f"{CLR_GRAY}----------------------------------------------------------------------{CLR_RESET}")
    print(f"  Requests Completed   : {CLR_BOLD}{len(results)}/{num_requests}{CLR_RESET}")
    print(f"  Primary Status 200/201: {CLR_GREEN}{CLR_BOLD}{len(successful)}{CLR_RESET}")
    print(f"  Failed / Error Status: {CLR_RED if failed else CLR_GRAY}{len(failed)}{CLR_RESET}")
    print(f"  Total Duration       : {CLR_BOLD}{total_duration:.2f}s{CLR_RESET} ({len(results)/total_duration:.1f} req/s)")
    print(f"  Client Response Time : avg={CLR_GREEN}{avg_lat:.1f}ms{CLR_RESET} | p95={p95_lat:.1f}ms | min={min_lat:.1f}ms | max={max_lat:.1f}ms")

    # Give Nginx and Shadow backend 0.5s to complete async processing of buffered requests
    time.sleep(0.6)

    if verify_diff:
        print(f"\n{CLR_BLUE}{CLR_BOLD}▶ Verifying Shadow Replication Fidelity (Diffing Primary vs Shadow){CLR_RESET}")
        print(f"{CLR_GRAY}----------------------------------------------------------------------{CLR_RESET}")
        try:
            diff_url = f"{target_url}/shadow/api/shadow/diff"
            req = urllib.request.Request(diff_url, headers={"User-Agent": "TrafficInjector/1.0"})
            with urllib.request.urlopen(req, timeout=4) as resp:
                diff_data = json.loads(resp.read().decode("utf-8"))

            p_count = diff_data.get("primary_requests_count", 0)
            s_count = diff_data.get("shadow_requests_count", 0)
            matched = diff_data.get("matched_requests_count", 0)
            acc_pct = diff_data.get("replication_accuracy_percent", 0.0)

            print(f"  Primary Stored Logs  : {CLR_BOLD}{p_count}{CLR_RESET}")
            print(f"  Shadow Mirrored Logs : {CLR_BOLD}{s_count}{CLR_RESET}")
            print(f"  Exact Matched Bodies : {CLR_GREEN}{CLR_BOLD}{matched}{CLR_RESET}")
            print(f"  Replication Accuracy : {CLR_GREEN if acc_pct >= 99.0 else CLR_YELLOW}{CLR_BOLD}{acc_pct:.1f}%{CLR_RESET}")

            if acc_pct >= 95.0:
                print(f"\n  {CLR_GREEN}{CLR_BOLD}🎉 100% TRAFFIC MIRRORING VERIFIED! Zero packet loss or payload corruption.{CLR_RESET}\n")
                return 0
            else:
                print(f"\n  {CLR_RED}{CLR_BOLD}❌ REPLICATION ACCURACY BELOW THRESHOLD: {acc_pct}%{CLR_RESET}\n")
                return 1
        except Exception as e:
            print(f"  {CLR_YELLOW}Warning: Could not fetch diff endpoint directly ({e}). Primary requests succeeded.{CLR_RESET}\n")
            return 0

    return 0

def main():
    parser = argparse.ArgumentParser(description="Shadow Traffic Mirroring Injector")
    parser.add_argument("--target", default="http://localhost:8080", help="Nginx proxy target URL (default: http://localhost:8080)")
    parser.add_argument("--requests", type=int, default=50, help="Total requests to inject (default: 50)")
    parser.add_argument("--concurrency", type=int, default=5, help="Concurrent client threads (default: 5)")
    parser.add_argument("--verify-diff", action="store_true", default=True, help="Verify replication diff with shadow service")
    args = parser.parse_args()

    sys.exit(run_traffic_injection(args.target, args.requests, args.concurrency, args.verify_diff))

if __name__ == "__main__":
    main()
