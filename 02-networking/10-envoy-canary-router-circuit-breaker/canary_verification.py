#!/usr/bin/env python3
"""
Statistical Verification & Load Testing Tool for Envoy L7 Canary Router
Measures 90/10 traffic shifting accuracy, verifies header-based canary overrides (x-canary: true),
and validates automatic outlier detection circuit breaking.
"""

import argparse
import concurrent.futures
import json
import random
import sys
import time
import urllib.error
import urllib.request

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_BLUE = "\033[1;34m"
CLR_GRAY = "\033[0;90m"
CLR_MAGENTA = "\033[1;35m"

def send_request(target_url, index, is_canary_override=False, retries=2):
    url = f"{target_url}/api/v1/data"
    headers = {
        "User-Agent": "EnvoyCanaryVerifier/1.0",
        "Connection": "close",
        "X-Request-ID": f"verify-{int(time.time()*1000)}-{index:04d}"
    }
    if is_canary_override:
        headers["x-canary"] = "true"

    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers=headers, method="GET")
        start_t = time.time()
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                elapsed_ms = (time.time() - start_t) * 1000
                backend_ver = resp.headers.get("X-Backend-Version", "unknown")
                routing_rule = resp.headers.get("x-envoy-routing-rule", "unknown")
                return {
                    "success": True,
                    "status_code": resp.status,
                    "version": backend_ver,
                    "routing_rule": routing_rule,
                    "latency_ms": elapsed_ms
                }
        except urllib.error.HTTPError as e:
            elapsed_ms = (time.time() - start_t) * 1000
            backend_ver = e.headers.get("X-Backend-Version", "error") if e.headers else "error"
            return {
                "success": False,
                "status_code": e.code,
                "version": backend_ver,
                "latency_ms": elapsed_ms,
                "error": str(e)
            }
        except Exception as e:
            if attempt < retries:
                time.sleep(0.05)
                continue
            elapsed_ms = (time.time() - start_t) * 1000
            return {
                "success": False,
                "status_code": 0,
                "version": "unreachable",
                "latency_ms": elapsed_ms,
                "error": str(e)
            }

def test_weighted_traffic_split(target_url, num_requests=1000, concurrency=10):
    print(f"\n{CLR_BLUE}{CLR_BOLD}▶ Phase 1: Statistical 90/10 Weighted Canary Split Test ({num_requests} requests){CLR_RESET}")
    print(f"{CLR_GRAY}----------------------------------------------------------------------{CLR_RESET}")

    start_time = time.time()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(send_request, target_url, i + 1, False) for i in range(num_requests)]
        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())

    total_time = time.time() - start_time
    v1_results = [r for r in results if "v1.0.0" in r.get("version", "")]
    v2_results = [r for r in results if "v2.0.0" in r.get("version", "")]
    errors = [r for r in results if not r.get("success")]

    v1_count = len(v1_results)
    v2_count = len(v2_results)
    total_valid = v1_count + v2_count

    v1_pct = (v1_count / total_valid * 100.0) if total_valid > 0 else 0.0
    v2_pct = (v2_count / total_valid * 100.0) if total_valid > 0 else 0.0

    print(f"  Total Completed      : {CLR_BOLD}{len(results)}/{num_requests}{CLR_RESET} in {total_time:.2f}s ({len(results)/total_time:.1f} req/s)")
    print(f"  Service V1 (Stable)  : {CLR_GREEN}{CLR_BOLD}{v1_count}{CLR_RESET} requests ({CLR_BOLD}{v1_pct:.1f}%{CLR_RESET} - Target: 90.0%)")
    print(f"  Service V2 (Canary)  : {CLR_MAGENTA}{CLR_BOLD}{v2_count}{CLR_RESET} requests ({CLR_BOLD}{v2_pct:.1f}%{CLR_RESET} - Target: 10.0%)")
    print(f"  Failed / Errors      : {CLR_RED if errors else CLR_GRAY}{len(errors)}{CLR_RESET}")

    # Assert statistical tolerance (V1 between 84% and 96%, V2 between 4% and 16%)
    if 84.0 <= v1_pct <= 96.0 and 4.0 <= v2_pct <= 16.0:
        print(f"  Status               : {CLR_GREEN}{CLR_BOLD}✓ STATISTICAL 90/10 SPLIT PASSED{CLR_RESET}")
        return True
    else:
        print(f"  Status               : {CLR_RED}{CLR_BOLD}❌ DISTRIBUTION OUT OF TOLERANCE ({v1_pct:.1f}% / {v2_pct:.1f}%){CLR_RESET}")
        return False

def test_header_override(target_url, num_requests=100, concurrency=5):
    print(f"\n{CLR_BLUE}{CLR_BOLD}▶ Phase 2: Header-Based Canary Override Test ('x-canary: true' -> 100% V2){CLR_RESET}")
    print(f"{CLR_GRAY}----------------------------------------------------------------------{CLR_RESET}")

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(send_request, target_url, i + 1, True) for i in range(num_requests)]
        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())

    v2_count = sum(1 for r in results if "v2.0.0" in r.get("version", ""))
    override_rules = sum(1 for r in results if r.get("routing_rule") == "header-canary-override")

    print(f"  Requests Dispatched  : {CLR_BOLD}{num_requests}{CLR_RESET} (with header 'x-canary: true')")
    print(f"  Routed to V2 Canary  : {CLR_GREEN}{CLR_BOLD}{v2_count}/{num_requests}{CLR_RESET} (100.0%)")
    print(f"  Header Match Rules   : {CLR_GREEN}{CLR_BOLD}{override_rules}/{num_requests}{CLR_RESET}")

    if v2_count == num_requests:
        print(f"  Status               : {CLR_GREEN}{CLR_BOLD}✓ 100% HEADER CANARY OVERRIDE PASSED{CLR_RESET}")
        return True
    else:
        print(f"  Status               : {CLR_RED}{CLR_BOLD}❌ OVERRIDE FAILED (Expected {num_requests}, got {v2_count}){CLR_RESET}")
        return False

def test_circuit_breaker(target_url, canary_backend_url="http://localhost:8002", envoy_admin_url="http://localhost:9901"):
    print(f"\n{CLR_BLUE}{CLR_BOLD}▶ Phase 3: Outlier Detection & Circuit Breaker Auto-Ejection Test{CLR_RESET}")
    print(f"{CLR_GRAY}----------------------------------------------------------------------{CLR_RESET}")

    print(f"  1. Injecting 500 Internal Server Errors on Canary Backend ({canary_backend_url})...")
    try:
        fault_payload = json.dumps({"enabled": True, "status_code": 500, "count": 20}).encode("utf-8")
        req = urllib.request.Request(f"{canary_backend_url}/api/canary/simulate-fault", data=fault_payload, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=3) as resp:
            pass
    except Exception as e:
        print(f"  {CLR_YELLOW}Warning: Could not contact Canary backend directly on {canary_backend_url}: {e}{CLR_RESET}")

    print("  2. Sending burst traffic to Envoy to trigger Outlier Detection (consecutive_5xx: 3)...")
    for i in range(8):
        send_request(target_url, i + 1, True)
        time.sleep(0.05)

    # Wait for Envoy Outlier Detection sweep (interval: 1s) to enforce host ejection
    time.sleep(1.2)

    print("  3. Inspecting Envoy Admin metrics for active host ejections...")
    ejections_enforced = 0
    try:
        req = urllib.request.Request(f"{envoy_admin_url}/stats?filter=cluster.service_v2.outlier_detection.ejections_enforced_total")
        with urllib.request.urlopen(req, timeout=3) as resp:
            content = resp.read().decode("utf-8")
            for line in content.splitlines():
                if "ejections_enforced_total:" in line:
                    ejections_enforced = int(line.split(":")[1].strip())
    except Exception as e:
        print(f"  {CLR_YELLOW}Warning querying Envoy admin stats: {e}{CLR_RESET}")

    print(f"  Envoy Ejections Count: {CLR_GREEN}{CLR_BOLD}{ejections_enforced}{CLR_RESET} enforced ejections on service_v2")

    # Reset fault simulation
    try:
        reset_payload = json.dumps({"enabled": False}).encode("utf-8")
        req = urllib.request.Request(f"{canary_backend_url}/api/canary/simulate-fault", data=reset_payload, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=3) as resp:
            pass
    except Exception:
        pass

    if ejections_enforced >= 1:
        print(f"  Status               : {CLR_GREEN}{CLR_BOLD}✓ OUTLIER DETECTION EJECTION VERIFIED ({ejections_enforced} ejections enforced){CLR_RESET}")
        return True
    else:
        print(f"  Status               : {CLR_RED}{CLR_BOLD}❌ OUTLIER DETECTION EJECTION FAILED{CLR_RESET}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Envoy L7 Canary Router & Circuit Breaker Verification Tool")
    parser.add_argument("--target", default="http://localhost:10000", help="Envoy Ingress URL (default: http://localhost:10000)")
    parser.add_argument("--canary-backend", default="http://localhost:8002", help="Direct Canary Backend URL (default: http://localhost:8002)")
    parser.add_argument("--envoy-admin", default="http://localhost:9901", help="Envoy Admin URL (default: http://localhost:9901)")
    parser.add_argument("--requests", type=int, default=1000, help="Total requests for statistical 90/10 test (default: 1000)")
    parser.add_argument("--concurrency", type=int, default=10, help="Concurrency worker threads (default: 10)")
    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🔀 Envoy L7 Canary Router & Circuit Breaker Verification{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_GRAY}Envoy Ingress    : {CLR_BOLD}{args.target}{CLR_RESET}")
    print(f"{CLR_GRAY}Sample Size      : {CLR_BOLD}{args.requests} requests{CLR_RESET}")
    print(f"{CLR_GRAY}Concurrency      : {CLR_BOLD}{args.concurrency} workers{CLR_RESET}")

    p1 = test_weighted_traffic_split(args.target, args.requests, args.concurrency)
    p2 = test_header_override(args.target, 100, args.concurrency)
    p3 = test_circuit_breaker(args.target, args.canary_backend, args.envoy_admin)

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    if p1 and p2 and p3:
        print(f"  {CLR_GREEN}{CLR_BOLD}🎉 ALL ENVOY L7 CANARY & CIRCUIT BREAKER TESTS PASSED!{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"  {CLR_RED}{CLR_BOLD}❌ SOME VERIFICATION CHECKS FAILED.{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
