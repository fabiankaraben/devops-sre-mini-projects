#!/usr/bin/env python3
"""
validate_probes.py - Automated Blackbox Exporter Verification Suite

Queries Prometheus PromQL API to assert the correctness of synthetic probe executions
across HTTP GET (2xx/500/404), HTTP POST, Body Regex Validation, and Raw TCP Sockets.
"""

import sys
import time
import urllib.parse
import urllib.request
import json

CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_WHITE = "\033[1;37m"

PROMETHEUS_URL = "http://localhost:9090"

total_tests = 0
passed_tests = 0
failed_tests = 0


def record_pass(test_name: str, message: str):
    global total_tests, passed_tests
    total_tests += 1
    passed_tests += 1
    print(f"  [{CLR_GREEN}PASS{CLR_RESET}] {test_name}: {message}")


def record_fail(test_name: str, message: str):
    global total_tests, failed_tests
    total_tests += 1
    failed_tests += 1
    print(f"  [{CLR_RED}FAIL{CLR_RESET}] {test_name}: {message}")


def query_prometheus(expr: str):
    url = f"{PROMETHEUS_URL}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    req = urllib.request.Request(url, headers={"User-Agent": "ProbeValidator/1.0"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        if data.get("status") != "success":
            raise RuntimeError(f"PromQL execution failed: {data}")
        return data.get("data", {}).get("result", [])


def main():
    print(f"{CLR_CYAN}{CLR_BOLD}")
    print("======================================================================")
    print("  🔍 Prometheus Blackbox Exporter - Synthetic Probes Test Suite")
    print("======================================================================")
    print(f"{CLR_RESET}")

    # Allow a brief window for scrapes to occur
    print(f"{CLR_YELLOW}▶ Awaiting initial Blackbox scrape cycles...{CLR_RESET}")
    time.sleep(4)

    # --------------------------------------------------------------------------
    # 1. Healthy HTTP 2xx Probe Assertion
    # --------------------------------------------------------------------------
    print(f"\n{CLR_YELLOW}▶ [1/6] Verifying Healthy HTTP Endpoint Probing...{CLR_RESET}")
    try:
        res = query_prometheus('probe_success{job="probe_http_healthy"}')
        if res and float(res[0]["value"][1]) == 1.0:
            record_pass("Healthy HTTP Probe", f"probe_success == 1.0 for {res[0]['metric'].get('instance')}")
        else:
            record_fail("Healthy HTTP Probe", f"Expected probe_success == 1.0, got {res}")
    except Exception as e:
        record_fail("Healthy HTTP Probe", f"Query error: {e}")

    # --------------------------------------------------------------------------
    # 2. Failing Endpoints (500 and 404)
    # --------------------------------------------------------------------------
    print(f"\n{CLR_YELLOW}▶ [2/6] Verifying Failing Endpoints (500 Error & 404 Not Found)...{CLR_RESET}")
    try:
        res_500 = query_prometheus('probe_success{instance=~".*failing-500"}')
        if res_500 and float(res_500[0]["value"][1]) == 0.0:
            record_pass("HTTP 500 Failure Probe", "Correctly identified probe_success == 0.0 on 500 error.")
        else:
            record_fail("HTTP 500 Failure Probe", f"Expected probe_success == 0.0, got {res_500}")

        res_404 = query_prometheus('probe_success{instance=~".*not-found-404"}')
        if res_404 and float(res_404[0]["value"][1]) == 0.0:
            record_pass("HTTP 404 Failure Probe", "Correctly identified probe_success == 0.0 on 404 Not Found.")
        else:
            record_fail("HTTP 404 Failure Probe", f"Expected probe_success == 0.0, got {res_404}")
    except Exception as e:
        record_fail("Failing Endpoints", f"Query error: {e}")

    # --------------------------------------------------------------------------
    # 3. HTTP Content / Regex Body Validation
    # --------------------------------------------------------------------------
    print(f"\n{CLR_YELLOW}▶ [3/6] Verifying HTTP Response Body Regex Matching (http_custom_match)...{CLR_RESET}")
    try:
        # Healthy body matches '.*"status":\s*"UP".*' -> probe_success == 1.0
        res_match_ok = query_prometheus('probe_success{job="probe_http_body_match",instance=~".*healthy"}')
        if res_match_ok and float(res_match_ok[0]["value"][1]) == 1.0:
            record_pass("Content Match (Valid)", "probe_success == 1.0 when response body matched regex.")
        else:
            record_fail("Content Match (Valid)", f"Expected probe_success == 1.0, got {res_match_ok}")

        # Unhealthy body has status DEGRADED -> regex mismatch -> probe_success == 0.0
        res_match_fail = query_prometheus('probe_success{job="probe_http_body_match",instance=~".*unhealthy-body"}')
        if res_match_fail and float(res_match_fail[0]["value"][1]) == 0.0:
            record_pass("Content Match (Mismatch)", "probe_success == 0.0 when response body contained DEGRADED status.")
        else:
            record_fail("Content Match (Mismatch)", f"Expected probe_success == 0.0, got {res_match_fail}")
    except Exception as e:
        record_fail("Content Validation", f"Query error: {e}")

    # --------------------------------------------------------------------------
    # 4. HTTP POST Probing with Payload
    # --------------------------------------------------------------------------
    print(f"\n{CLR_YELLOW}▶ [4/6] Verifying HTTP POST Probing (http_post_2xx)...{CLR_RESET}")
    try:
        res_post = query_prometheus('probe_success{job="probe_http_post"}')
        if res_post and float(res_post[0]["value"][1]) == 1.0:
            record_pass("HTTP POST Probe", "probe_success == 1.0 for JSON POST payload probe.")
        else:
            record_fail("HTTP POST Probe", f"Expected probe_success == 1.0, got {res_post}")
    except Exception as e:
        record_fail("HTTP POST Probe", f"Query error: {e}")

    # --------------------------------------------------------------------------
    # 5. Raw TCP Socket Reachability Probe
    # --------------------------------------------------------------------------
    print(f"\n{CLR_YELLOW}▶ [5/6] Verifying Raw TCP Socket Probing (tcp_connect)...{CLR_RESET}")
    try:
        res_tcp = query_prometheus('probe_success{job="probe_tcp_socket"}')
        if res_tcp and float(res_tcp[0]["value"][1]) == 1.0:
            record_pass("TCP Socket Probe", f"probe_success == 1.0 for TCP port {res_tcp[0]['metric'].get('instance')}")
        else:
            record_fail("TCP Socket Probe", f"Expected probe_success == 1.0, got {res_tcp}")
    except Exception as e:
        record_fail("TCP Socket Probe", f"Query error: {e}")

    # --------------------------------------------------------------------------
    # 6. Response Duration & Latency Measurement
    # --------------------------------------------------------------------------
    print(f"\n{CLR_YELLOW}▶ [6/6] Verifying Probe Latency Metrics (probe_duration_seconds)...{CLR_RESET}")
    try:
        res_slow = query_prometheus('probe_duration_seconds{job="probe_http_slow"}')
        if res_slow:
            duration = float(res_slow[0]["value"][1])
            if duration >= 0.35:
                record_pass("Slow Probe Latency", f"Accurately captured synthetic delay: {duration:.4f}s (>= 0.35s)")
            else:
                record_fail("Slow Probe Latency", f"Duration was unexpectedly low: {duration}s")
        else:
            record_fail("Slow Probe Latency", "No duration samples returned.")
    except Exception as e:
        record_fail("Latency Verification", f"Query error: {e}")

    # --------------------------------------------------------------------------
    # Test Summary Report
    # --------------------------------------------------------------------------
    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  📊 SYNTHETIC PROBE TEST SUMMARY{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  Total Probe Tests Executed : {total_tests}")
    print(f"  Passed                     : {CLR_GREEN}{passed_tests}{CLR_RESET}")
    print(f"  Failed                     : {CLR_RED}{failed_tests}{CLR_RESET}")
    print(f"{CLR_CYAN}----------------------------------------------------------------------{CLR_RESET}")

    if failed_tests == 0:
        print(f"  {CLR_GREEN}{CLR_BOLD}🎉 ALL BLACKBOX SYNTHETIC PROBES PASSED!{CLR_RESET}")
        print("  Multi-protocol probing (HTTP GET/POST, Content Regex, TCP) is validated.\n")
        sys.exit(0)
    else:
        print(f"  {CLR_RED}{CLR_BOLD}❌ SOME PROBE VALIDATION TESTS FAILED.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
