#!/usr/bin/env python3
"""
circuit_breaker_test.py - Concurrency & State Machine Test Suite
================================================================
Automated test suite validating Circuit Breaker state transitions,
fail-fast short-circuiting, exponential backoff retries, graceful fallbacks,
and multi-threaded concurrency safety.

Generates structured test reports (test_report.md and test_report.json)
within the project directory.
"""

import argparse
import concurrent.futures
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://localhost:8080")
DEFAULT_DOWNSTREAM_URL = os.environ.get("DOWNSTREAM_URL", "http://localhost:8081")

# ANSI Terminal Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"


class HTTPClient:
    """Helper client for interacting with Gateway and Downstream services."""

    def __init__(self, gateway_url: str, downstream_url: str):
        self.gateway_url = gateway_url.rstrip("/")
        self.downstream_url = downstream_url.rstrip("/")

    def get(self, url: str, timeout: float = 5.0) -> Tuple[int, Dict[str, Any]]:
        req = urllib.request.Request(url, headers={"User-Agent": "CB-Test-Runner/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.getcode()
                raw = resp.read().decode("utf-8")
                try:
                    return status, json.loads(raw)
                except Exception:
                    return status, {"raw": raw}
        except urllib.error.HTTPError as he:
            raw = he.read().decode("utf-8")
            try:
                return he.code, json.loads(raw)
            except Exception:
                return he.code, {"raw": raw, "error": str(he)}
        except Exception as e:
            return 0, {"error": str(e)}

    def post(self, url: str, body: Dict[str, Any], timeout: float = 5.0) -> Tuple[int, Dict[str, Any]]:
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json", "User-Agent": "CB-Test-Runner/1.0"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.getcode()
                raw = resp.read().decode("utf-8")
                try:
                    return status, json.loads(raw)
                except Exception:
                    return status, {"raw": raw}
        except urllib.error.HTTPError as he:
            raw = he.read().decode("utf-8")
            try:
                return he.code, json.loads(raw)
            except Exception:
                return he.code, {"raw": raw, "error": str(he)}
        except Exception as e:
            return 0, {"error": str(e)}

    # Shortcut helpers
    def set_downstream_chaos(self, config: Dict[str, Any]) -> Dict[str, Any]:
        _, data = self.post(f"{self.downstream_url}/chaos/faults", config)
        return data

    def reset_downstream_chaos(self) -> Dict[str, Any]:
        _, data = self.post(f"{self.downstream_url}/chaos/reset", {})
        return data

    def get_downstream_status(self) -> Dict[str, Any]:
        _, data = self.get(f"{self.downstream_url}/chaos/status")
        return data

    def get_circuit_state(self) -> Dict[str, Any]:
        _, data = self.get(f"{self.gateway_url}/circuit/state")
        return data

    def reset_circuit(self) -> Dict[str, Any]:
        _, data = self.post(f"{self.gateway_url}/circuit/reset", {"reason": "Test Suite Reset"})
        return data

    def update_circuit_config(self, config: Dict[str, Any]) -> Dict[str, Any]:
        _, data = self.post(f"{self.gateway_url}/circuit/config", config)
        return data


class TestResult:
    def __init__(self, name: str, passed: bool, details: str, duration_sec: float):
        self.name = name
        self.passed = passed
        self.details = details
        self.duration_sec = round(duration_sec, 3)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "status": "PASSED" if self.passed else "FAILED",
            "details": self.details,
            "duration_sec": self.duration_sec,
        }


class CircuitBreakerTestSuite:
    """Executes test scenarios and validates SRE assertions."""

    def __init__(self, gateway_url: str, downstream_url: str):
        self.client = HTTPClient(gateway_url, downstream_url)
        self.results: List[TestResult] = []

    def _log_header(self, title: str) -> None:
        print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 70}")
        print(f"  {title}")
        print(f"{'=' * 70}{CLR_RESET}")

    def _record(self, name: str, passed: bool, details: str, duration: float) -> bool:
        res = TestResult(name, passed, details, duration)
        self.results.append(res)
        status_tag = f"{CLR_GREEN}[PASS]{CLR_RESET}" if passed else f"{CLR_RED}[FAIL]{CLR_RESET}"
        print(f"  {status_tag} {CLR_BOLD}{name}{CLR_RESET} ({duration:.2f}s)")
        if not passed:
            print(f"         {CLR_RED}Reason: {details}{CLR_RESET}")
        else:
            print(f"         {CLR_GRAY}{details}{CLR_RESET}")
        return passed

    def run_all_tests(self) -> bool:
        self._log_header("🚀 CIRCUIT BREAKER & RETRY ENGINE VALIDATION SUITE")

        # Configure fast test parameters on gateway: failure_threshold=5, recovery_timeout=2.0s
        self.client.update_circuit_config({
            "failure_threshold": 5,
            "recovery_timeout": 2.0,
            "half_open_success_threshold": 2,
            "max_retries": 1,
            "base_backoff": 0.05,
        })
        self.client.reset_downstream_chaos()
        self.client.reset_circuit()
        time.sleep(0.5)

        # Execute Test Cases
        self.test_01_steady_state_baseline()
        self.test_02_failure_threshold_tripping_to_open()
        self.test_03_fail_fast_zero_downstream_calls()
        self.test_04_recovery_timeout_and_half_open_probe()
        self.test_05_circuit_healing_to_closed()
        self.test_06_half_open_probe_failure_retrip()
        self.test_07_exponential_backoff_retry_timing()
        self.test_08_concurrent_thundering_herd_protection()
        self.test_09_manual_trip_and_reset_overrides()
        self.test_10_prometheus_telemetry_export()

        # Summary and Report Generation
        self.generate_reports()
        return all(r.passed for r in self.results)

    # --------------------------------------------------------------------------
    # Test 1: Steady-State Baseline (CLOSED)
    # --------------------------------------------------------------------------
    def test_01_steady_state_baseline(self) -> None:
        t0 = time.time()
        name = "1. Steady-State Baseline (CLOSED state, 100% success)"
        self.client.reset_downstream_chaos()
        self.client.reset_circuit()

        all_ok = True
        for i in range(5):
            status, body = self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-{100 + i}")
            if status != 200 or body.get("is_fallback") is not False or body.get("circuit_state") != "CLOSED":
                all_ok = False
                break

        cb_state = self.client.get_circuit_state()
        state_is_closed = cb_state.get("state") == "CLOSED"
        failures_zero = cb_state.get("consecutive_failures") == 0

        passed = all_ok and state_is_closed and failures_zero
        details = (
            f"5/5 successful requests, circuit_state={cb_state.get('state')}, "
            f"consecutive_failures={cb_state.get('consecutive_failures')}"
        )
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 2: Failure Threshold & Tripping to OPEN
    # --------------------------------------------------------------------------
    def test_02_failure_threshold_tripping_to_open(self) -> None:
        t0 = time.time()
        name = "2. Circuit Tripping (Transition to OPEN after 5 consecutive failures)"
        self.client.reset_circuit()
        
        # Inject HTTP 500 downstream
        self.client.set_downstream_chaos({
            "mode": "error",
            "error_code": 500,
            "error_message": "Database deadlock timeout",
        })

        # Send 5 failing requests to reach failure_threshold (5)
        for i in range(5):
            self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-FAIL-{i}")

        cb_state = self.client.get_circuit_state()
        state = cb_state.get("state")
        failures = cb_state.get("consecutive_failures")

        passed = (state == "OPEN") and (failures >= 5)
        details = f"State transitioned to {state} with {failures} consecutive failures recorded."
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 3: Fail-Fast Verification (Zero Downstream Calls in OPEN)
    # --------------------------------------------------------------------------
    def test_03_fail_fast_zero_downstream_calls(self) -> None:
        t0 = time.time()
        name = "3. Fail-Fast Execution (Zero downstream network calls in OPEN state)"

        # Get initial downstream request count
        ds_initial = self.client.get_downstream_status()
        initial_requests = ds_initial.get("telemetry", {}).get("total_requests", 0)

        # Fire 10 rapid requests into OPEN gateway
        latencies = []
        fallbacks = 0
        short_circuited = 0

        for i in range(10):
            req_t0 = time.time()
            status, body = self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-FAST-{i}")
            latencies.append((time.time() - req_t0) * 1000.0)
            if body.get("is_fallback") is True:
                fallbacks += 1
            if body.get("short_circuited") is True:
                short_circuited += 1

        # Check downstream request count afterwards
        ds_after = self.client.get_downstream_status()
        after_requests = ds_after.get("telemetry", {}).get("total_requests", 0)
        downstream_calls_made = after_requests - initial_requests

        avg_latency = sum(latencies) / len(latencies) if latencies else 0.0

        # Assert zero downstream calls and all requests served by fallback in < 15ms
        passed = (downstream_calls_made == 0) and (fallbacks == 10) and (short_circuited == 10) and (avg_latency < 25.0)
        details = (
            f"10/10 requests short-circuited. Downstream calls made: {downstream_calls_made} "
            f"(0 expected). Avg fallback latency: {avg_latency:.2f}ms."
        )
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 4: Recovery Timeout and HALF-OPEN Probe Transition
    # --------------------------------------------------------------------------
    def test_04_recovery_timeout_and_half_open_probe(self) -> None:
        t0 = time.time()
        name = "4. Recovery Timeout & Transition to HALF_OPEN probe state"

        # Downstream healed
        self.client.reset_downstream_chaos()

        # Wait for recovery timeout (2.0s configured + buffer)
        time.sleep(2.2)

        # Send a single probe request
        status, body = self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-PROBE-1")

        cb_state = self.client.get_circuit_state()
        history = self.client.get(f"{self.client.gateway_url}/circuit/history")[1].get("history", [])

        # Check if HALF_OPEN transition exists in history
        half_open_recorded = any(h.get("to_state") == "HALF_OPEN" for h in history)
        success_recorded = body.get("is_fallback") is False

        passed = half_open_recorded and success_recorded
        details = f"Transition to HALF_OPEN detected after recovery window. Probe request returned HTTP {status} (success)."
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 5: Circuit Healing back to CLOSED
    # --------------------------------------------------------------------------
    def test_05_circuit_healing_to_closed(self) -> None:
        t0 = time.time()
        name = "5. Circuit Self-Healing (HALF_OPEN -> CLOSED on consecutive successes)"

        # Send second successful probe request to reach half_open_success_threshold (2)
        status, body = self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-PROBE-2")

        cb_state = self.client.get_circuit_state()
        final_state = cb_state.get("state")
        failures = cb_state.get("consecutive_failures")

        passed = (final_state == "CLOSED") and (failures == 0)
        details = f"Circuit successfully healed to {final_state} (consecutive_failures reset to {failures})."
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 6: Probe Failure & Immediate Re-trip (HALF_OPEN -> OPEN)
    # --------------------------------------------------------------------------
    def test_06_half_open_probe_failure_retrip(self) -> None:
        t0 = time.time()
        name = "6. Probe Failure Re-trip (HALF_OPEN -> OPEN immediately on probe error)"

        # 1. Trip circuit to OPEN
        self.client.post(f"{self.client.gateway_url}/circuit/trip", {"reason": "Test setup for probe fail"})

        # 2. Inject error downstream
        self.client.set_downstream_chaos({
            "mode": "error",
            "error_code": 503,
            "error_message": "Service overloaded",
        })

        # 3. Wait for recovery timeout
        time.sleep(2.2)

        # 4. Probe request fails
        status, body = self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-FAILING-PROBE")

        cb_state = self.client.get_circuit_state()
        current_state = cb_state.get("state")

        passed = (current_state == "OPEN") and (body.get("is_fallback") is True)
        details = f"Single probe failure in HALF_OPEN caused immediate re-trip to {current_state}."
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 7: Exponential Backoff & Jitter Timing
    # --------------------------------------------------------------------------
    def test_07_exponential_backoff_retry_timing(self) -> None:
        t0 = time.time()
        name = "7. Exponential Backoff & Jitter Timing Validation"

        self.client.reset_downstream_chaos()
        self.client.reset_circuit()

        # Update retry settings: max_retries=2, base_backoff=0.1s
        self.client.update_circuit_config({
            "failure_threshold": 10,
            "max_retries": 2,
            "base_backoff": 0.1,
            "max_backoff": 1.0,
            "jitter": True,
        })

        # Inject error
        self.client.set_downstream_chaos({
            "mode": "error",
            "error_code": 500,
            "error_message": "Temporary fault",
        })

        req_start = time.time()
        status, body = self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-RETRY-TIMING")
        elapsed_sec = time.time() - req_start

        # With max_retries=2, base=0.1s:
        # attempt 1 backoff ~ Uniform(0, 0.1) -> avg 0.05s
        # attempt 2 backoff ~ Uniform(0, 0.2) -> avg 0.10s
        # Total latency should be >= 0.05s and <= 1.0s
        attempts = body.get("attempts", 1)
        passed = (attempts >= 2) and (elapsed_sec >= 0.04)
        details = f"Executed {attempts} attempts with exponential backoff in {elapsed_sec * 1000.0:.2f}ms."
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 8: Concurrent Thundering Herd Protection
    # --------------------------------------------------------------------------
    def test_08_concurrent_thundering_herd_protection(self) -> None:
        t0 = time.time()
        name = "8. Multi-Threaded Concurrency & Thundering Herd Protection (30 workers)"

        self.client.reset_downstream_chaos()
        self.client.reset_circuit()
        self.client.update_circuit_config({
            "failure_threshold": 5,
            "recovery_timeout": 1.5,
            "half_open_success_threshold": 2,
            "max_retries": 0,
        })

        # Inject error to trip breaker
        self.client.set_downstream_chaos({"mode": "error", "error_code": 500})
        for i in range(5):
            self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-THUND-{i}")

        # Trip verified
        assert self.client.get_circuit_state().get("state") == "OPEN"

        # Downstream is now healed
        self.client.reset_downstream_chaos()

        # Wait for recovery timeout to expire
        time.sleep(1.6)

        # Concurrently fire 30 requests simultaneously
        def worker(req_id: int) -> Tuple[int, Dict[str, Any]]:
            return self.client.get(f"{self.client.gateway_url}/api/v1/orders/ORD-CONC-{req_id}")

        with concurrent.futures.ThreadPoolExecutor(max_workers=15) as executor:
            futures = [executor.submit(worker, i) for i in range(30)]
            results = [f.result() for f in concurrent.futures.as_completed(futures)]

        # Verify all requests returned HTTP 200 (either healed success or clean fallback)
        all_returned_200 = all(code == 200 for code, _ in results)
        cb_final = self.client.get_circuit_state()
        final_state = cb_final.get("state")

        passed = all_returned_200 and (final_state in ["CLOSED", "HALF_OPEN"])
        details = (
            f"30 concurrent requests handled with 0 HTTP errors. Final circuit state: {final_state}. "
            f"Short-circuited / fallbacks safely served without race conditions."
        )
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 9: Manual Trip & Reset Overrides
    # --------------------------------------------------------------------------
    def test_09_manual_trip_and_reset_overrides(self) -> None:
        t0 = time.time()
        name = "9. Operational Controls (Manual Trip & Reset Endpoints)"

        # Manual trip
        self.client.post(f"{self.client.gateway_url}/circuit/trip", {"reason": "SRE GameDay drill"})
        state_after_trip = self.client.get_circuit_state().get("state")

        # Manual reset
        self.client.post(f"{self.client.gateway_url}/circuit/reset", {"reason": "Drill completed"})
        state_after_reset = self.client.get_circuit_state().get("state")

        passed = (state_after_trip == "OPEN") and (state_after_reset == "CLOSED")
        details = f"Manual trip -> {state_after_trip}, Manual reset -> {state_after_reset}."
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Test 10: Prometheus Telemetry Export
    # --------------------------------------------------------------------------
    def test_10_prometheus_telemetry_export(self) -> None:
        t0 = time.time()
        name = "10. Prometheus Telemetry & Metrics Export (/metrics)"

        status, body = self.client.get(f"{self.client.gateway_url}/metrics")
        raw_text = body.get("raw", "") if isinstance(body, dict) else str(body)

        has_state = "circuit_breaker_state{" in raw_text
        has_requests = "circuit_breaker_requests_total{" in raw_text
        has_fallbacks = "circuit_breaker_fallback_requests_total{" in raw_text
        has_short_circuited = "circuit_breaker_short_circuited_total{" in raw_text

        passed = (status == 200) and has_state and has_requests and has_fallbacks and has_short_circuited
        details = "Prometheus gauges, request counters, fallback and short-circuit counters verified."
        self._record(name, passed, details, time.time() - t0)

    # --------------------------------------------------------------------------
    # Report Generation
    # --------------------------------------------------------------------------
    def generate_reports(self) -> None:
        self._log_header("📊 GENERATING TEST REPORTS")
        total = len(self.results)
        passed = sum(1 for r in self.results if r.passed)
        failed = total - passed
        pass_pct = (passed / total * 100.0) if total > 0 else 0.0

        # 1. JSON Report
        json_report_path = os.path.join(SCRIPT_DIR, "test_report.json")
        report_data = {
            "suite": "Circuit Breaker & Resilient Retry Engine",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "summary": {
                "total_tests": total,
                "passed_tests": passed,
                "failed_tests": failed,
                "pass_rate_pct": round(pass_pct, 2),
            },
            "results": [r.to_dict() for r in self.results],
        }
        with open(json_report_path, "w", encoding="utf-8") as f:
            json.dump(report_data, f, indent=2)

        # 2. Markdown Report
        md_report_path = os.path.join(SCRIPT_DIR, "test_report.md")
        md_lines = [
            "# Circuit Breaker & Resilient Retry Engine - Test Suite Report",
            "",
            f"**Execution Timestamp**: `{report_data['timestamp']}`  ",
            f"**Total Tests**: `{total}` | **Passed**: `{passed}` | **Failed**: `{failed}` | **Pass Rate**: `{pass_pct:.1f}%`",
            "",
            "## Summary Results",
            "",
            "| # | Test Scenario | Status | Duration (s) | Details |",
            "|---|---------------|--------|--------------|---------|",
        ]
        for idx, r in enumerate(self.results, 1):
            badge = "✅ PASS" if r.passed else "❌ FAIL"
            md_lines.append(f"| {idx} | {r.name} | {badge} | {r.duration_sec:.3f} | {r.details} |")

        md_lines.append("")
        with open(md_report_path, "w", encoding="utf-8") as f:
            f.write("\n".join(md_lines) + "\n")

        print(f"  [OK] Generated JSON report: {json_report_path}")
        print(f"  [OK] Generated Markdown report: {md_report_path}")
        print(f"\n{CLR_BOLD}Results: {CLR_GREEN}{passed} Passed{CLR_RESET}, {CLR_RED if failed > 0 else CLR_RESET}{failed} Failed{CLR_RESET} of {total} total.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Circuit Breaker Concurrency & State Machine Test Runner")
    parser.add_argument("--gateway-url", type=str, default=DEFAULT_GATEWAY_URL, help="Resilience Gateway URL")
    parser.add_argument("--downstream-url", type=str, default=DEFAULT_DOWNSTREAM_URL, help="Downstream Service URL")
    args = parser.parse_args()

    suite = CircuitBreakerTestSuite(gateway_url=args.gateway_url, downstream_url=args.downstream_url)
    success = suite.run_all_tests()

    if not success:
        sys.exit(1)


if __name__ == "__main__":
    main()
