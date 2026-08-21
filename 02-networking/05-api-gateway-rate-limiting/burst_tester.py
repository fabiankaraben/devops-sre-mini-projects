#!/usr/bin/env python3
"""
High-Concurrency Rate Limit & Burst Tester
Verifies:
  1. Gateway & Downstream API baseline health
  2. General API burst rate limiting (10r/s, burst=10 -> HTTP 429 on excess)
  3. Strict Auth brute-force protection (2r/s, burst=3 -> HTTP 429)
  4. Leaky bucket drain and automatic rate limit recovery
  5. Request body payload limits (client_max_body_size 1MB -> HTTP 413)
  6. Custom structured JSON error payloads and Retry-After headers
"""

import argparse
import concurrent.futures
import json
import sys
import time
import urllib.error
import urllib.request

# ANSI Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_BLUE = "\033[1;34m"
CLR_GRAY = "\033[0;90m"

TOTAL_TESTS = 0
PASSED_TESTS = 0
FAILED_TESTS = 0


def log_section(title):
    print(f"\n{CLR_BLUE}{CLR_BOLD}=== {title} ==={CLR_RESET}")


def assert_test(name, condition, details=""):
    global TOTAL_TESTS, PASSED_TESTS, FAILED_TESTS
    TOTAL_TESTS += 1
    if condition:
        print(f"  {CLR_GREEN}✔ PASS{CLR_RESET} [{name}] {details}")
        PASSED_TESTS += 1
    else:
        print(f"  {CLR_RED}✖ FAIL{CLR_RESET} [{name}] {details}")
        FAILED_TESTS += 1


def send_http_request(url, method="GET", data=None, headers=None):
    if headers is None:
        headers = {}
    if data is not None and isinstance(data, dict):
        data = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            latency = (time.perf_counter() - start) * 1000
            resp_body = response.read().decode("utf-8", errors="ignore")
            resp_headers = dict(response.headers)
            return {
                "status": response.status,
                "body": resp_body,
                "headers": resp_headers,
                "latency_ms": latency
            }
    except urllib.error.HTTPError as e:
        latency = (time.perf_counter() - start) * 1000
        resp_body = e.read().decode("utf-8", errors="ignore")
        resp_headers = dict(e.headers)
        return {
            "status": e.code,
            "body": resp_body,
            "headers": resp_headers,
            "latency_ms": latency
        }
    except Exception as e:
        return {
            "status": 0,
            "body": str(e),
            "headers": {},
            "latency_ms": 0
        }


def test_baseline(base_url):
    log_section("1. API Gateway & Downstream Health Verification")
    res = send_http_request(f"{base_url}/gateway-health")
    assert_test("Gateway Health Check", res["status"] == 200, f"(HTTP {res['status']})")

    res_api = send_http_request(f"{base_url}/api/v1/users")
    assert_test("Downstream Users API Reachable", res_api["status"] == 200, f"(HTTP {res_api['status']})")


def test_general_api_burst(base_url, burst_count=25):
    log_section(f"2. General API Burst Concurrency Test ({burst_count} Rapid Requests to /api/v1/users)")
    print(f"{CLR_GRAY}Policy: 10 requests/sec, burst=10 nodelay (Capacity: 20-21 concurrent requests){CLR_RESET}")

    url = f"{base_url}/api/v1/users"
    results = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=burst_count) as executor:
        futures = [executor.submit(send_http_request, url) for _ in range(burst_count)]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    status_200 = sum(1 for r in results if r["status"] == 200)
    status_429 = sum(1 for r in results if r["status"] == 429)
    errors = sum(1 for r in results if r["status"] not in (200, 429))

    print(f"  {CLR_CYAN}Results:{CLR_RESET} HTTP 200 OK: {CLR_GREEN}{status_200}{CLR_RESET} | HTTP 429 Rate Limited: {CLR_YELLOW}{status_429}{CLR_RESET} | Errors: {errors}")

    assert_test(
        "Burst Requests within capacity accepted (HTTP 200)",
        10 <= status_200 <= 22,
        f"(Processed: {status_200} requests)"
    )
    assert_test(
        "Excess Burst requests rate-limited (HTTP 429)",
        status_429 > 0,
        f"(Rate-limited: {status_429} requests)"
    )

    # Check 429 response structure
    sample_429 = next((r for r in results if r["status"] == 429), None)
    if sample_429:
        try:
            body_json = json.loads(sample_429["body"])
            has_error_field = "Too Many Requests" in body_json.get("error", "")
            has_retry_after = "Retry-After" in sample_429["headers"] or "retry-after" in sample_429["headers"]
            assert_test("HTTP 429 returns structured JSON payload", has_error_field)
            assert_test("HTTP 429 includes 'Retry-After' header", has_retry_after)
        except Exception:
            assert_test("HTTP 429 returns structured JSON payload", False)


def test_auth_bruteforce_protection(base_url, attempts=10):
    log_section(f"3. Strict Auth Brute-Force Shield ({attempts} Rapid Logins to /api/v1/auth/login)")
    print(f"{CLR_GRAY}Policy: 2 requests/sec, burst=3 nodelay (Capacity: ~5 requests){CLR_RESET}")

    url = f"{base_url}/api/v1/auth/login"
    payload = {"username": "admin", "password": "password123"}
    results = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=attempts) as executor:
        futures = [executor.submit(send_http_request, url, "POST", payload) for _ in range(attempts)]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    status_200 = sum(1 for r in results if r["status"] == 200)
    status_429 = sum(1 for r in results if r["status"] == 429)

    print(f"  {CLR_CYAN}Results:{CLR_RESET} Logins Allowed: {CLR_GREEN}{status_200}{CLR_RESET} | Brute-force Blocked: {CLR_RED}{status_429}{CLR_RESET}")

    assert_test(
        "Strict Auth limit triggers quickly (HTTP 429 on burst)",
        status_429 >= 3,
        f"(Blocked {status_429}/{attempts} attempts)"
    )


def test_leaky_bucket_recovery(base_url):
    log_section("4. Leaky-Bucket Drain & Auto-Recovery Test")
    print(f"{CLR_GRAY}Waiting 1.5s for the shared-memory token bucket to drain...{CLR_RESET}")
    time.sleep(1.5)

    res = send_http_request(f"{base_url}/api/v1/users")
    assert_test(
        "Client unblocked after bucket drain (HTTP 200)",
        res["status"] == 200,
        f"(HTTP {res['status']})"
    )


def test_payload_size_limits(base_url):
    log_section("5. Payload Size Limit Enforcement (client_max_body_size 1MB)")

    # 1. Allowed payload: 100KB
    small_payload = b"A" * (100 * 1024)
    res_small = send_http_request(f"{base_url}/api/v1/upload", "POST", small_payload, {"Content-Type": "application/octet-stream"})
    assert_test(
        "Upload <= 1MB successfully processed (HTTP 200)",
        res_small["status"] == 200,
        f"(Received: 100KB -> HTTP {res_small['status']})"
    )

    # 2. Exceeded payload: 2MB
    large_payload = b"B" * (2 * 1024 * 1024)
    res_large = send_http_request(f"{base_url}/api/v1/upload", "POST", large_payload, {"Content-Type": "application/octet-stream"})
    assert_test(
        "Upload > 1MB rejected with HTTP 413 Payload Too Large",
        res_large["status"] == 413,
        f"(Sent: 2MB -> HTTP {res_large['status']})"
    )

    try:
        body_413 = json.loads(res_large["body"])
        assert_test("HTTP 413 returns structured JSON error body", body_413.get("status") == 413)
    except Exception:
        assert_test("HTTP 413 returns structured JSON error body", False)


def main():
    parser = argparse.ArgumentParser(description="API Gateway Rate Limiting Burst Tester")
    parser.add_argument("--url", default="http://127.0.0.1:8085", help="API Gateway Base URL (default: http://127.0.0.1:8085)")
    parser.add_argument("--concurrency", type=int, default=25, help="Number of concurrent burst requests")
    args = parser.parse_args()

    print(f"{CLR_CYAN}{CLR_BOLD}")
    print("======================================================================")
    print("  🛡️  API Gateway Leaky-Bucket Rate Limiter Concurrency Test Suite")
    print("======================================================================")
    print(f"{CLR_RESET}")
    print(f"{CLR_GRAY}Target API Gateway : {CLR_BOLD}{args.url}{CLR_RESET}")
    print(f"{CLR_GRAY}Burst Concurrency  : {CLR_BOLD}{args.concurrency}{CLR_RESET}\n")

    test_baseline(args.url)
    test_general_api_burst(args.url, args.concurrency)
    test_auth_bruteforce_protection(args.url)
    test_leaky_bucket_recovery(args.url)
    test_payload_size_limits(args.url)

    print("\n======================================================================")
    if FAILED_TESTS == 0:
        print(f"  {CLR_GREEN}{CLR_BOLD}🎉 ALL TESTS PASSED! ({PASSED_TESTS}/{TOTAL_TESTS}){CLR_RESET}")
    else:
        print(f"  {CLR_RED}{CLR_BOLD}❌ TEST SUITE FAILED ({FAILED_TESTS} failed out of {TOTAL_TESTS}){CLR_RESET}")
    print("======================================================================\n")

    if FAILED_TESTS > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
