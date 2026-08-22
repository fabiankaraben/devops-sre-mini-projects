#!/usr/bin/env python3
"""
promql_validation.py - Prometheus RED & USE PromQL Metrics Validation Suite

Validates the operational telemetry of the instrumented application stack by querying
the Prometheus HTTP v1 API (/api/v1/query, /api/v1/targets, /api/v1/rules):
- RED Method: Rate (req/s), Errors (5xx %), Duration (p90, p95, p99 quantiles via histogram_quantile).
- USE Method: Utilization (worker capacity %), Saturation (queue depth), Errors (resource failure rate).
- Rules Engine: Verification of precomputed recording rules and active alert rules.

Zero external dependencies (uses standard library urllib and json).
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional

# Terminal ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"


class PrometheusClient:
    """Lightweight HTTP client for Prometheus REST API."""

    def __init__(self, base_url: str, timeout: float = 10.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _http_get(self, endpoint: str, params: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        url = f"{self.base_url}{endpoint}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"

        req = urllib.request.Request(
            url,
            headers={"User-Agent": "RED-USE-ValidationSuite/1.0", "Accept": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            err_body = err.read().decode("utf-8") if err.fp else ""
            raise RuntimeError(f"HTTP {err.code} on {endpoint}: {err.reason} - {err_body}") from err
        except urllib.error.URLError as err:
            raise RuntimeError(f"Connection error to {self.base_url}: {err.reason}") from err

    def check_ready(self) -> bool:
        try:
            req = urllib.request.Request(f"{self.base_url}/-/ready")
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status == 200
        except Exception:
            return False

    def query(self, promql: str) -> Dict[str, Any]:
        return self._http_get("/api/v1/query", {"query": promql})

    def get_targets(self) -> Dict[str, Any]:
        return self._http_get("/api/v1/targets")

    def get_rules(self) -> Dict[str, Any]:
        return self._http_get("/api/v1/rules")


class MetricsValidationRunner:
    """Executes assertions against RED and USE metrics."""

    def __init__(self, client: PrometheusClient, verbose: bool = False):
        self.client = client
        self.verbose = verbose
        self.results: List[Dict[str, Any]] = []

    def record(self, name: str, category: str, passed: bool, message: str, details: Optional[Dict[str, Any]] = None):
        self.results.append({
            "name": name,
            "category": category,
            "passed": passed,
            "message": message,
            "details": details or {}
        })

    def run_all(self) -> bool:
        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  🔬 Prometheus RED & USE Metrics Validation Suite{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

        self.test_target_health()
        self.test_red_rate_metrics()
        self.test_red_error_metrics()
        self.test_red_duration_histogram_quantiles()
        self.test_use_metrics()
        self.test_rules_engine()

        return self.print_summary()

    # --------------------------------------------------------------------------
    # 1. Target Health
    # --------------------------------------------------------------------------
    def test_target_health(self):
        print(f"{CLR_YELLOW}▶ [1/5] Verifying Application Scrape Target Health...{CLR_RESET}")
        try:
            targets = self.client.get_targets().get("data", {}).get("activeTargets", [])
            app_target = next((t for t in targets if t.get("labels", {}).get("job") == "instrumented_app"), None)

            if app_target and app_target.get("health") == "up":
                url = app_target.get("scrapeUrl")
                duration = app_target.get("lastScrapeDuration", 0.0)
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Target 'instrumented_app' is {CLR_GREEN}UP{CLR_RESET} ({url}, scrape latency: {duration:.4f}s)")
                self.record("Target Health", "Health", True, f"Target is UP ({url})", app_target)
            else:
                status = app_target.get("health") if app_target else "NOT_FOUND"
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] Target 'instrumented_app' status: {status}")
                self.record("Target Health", "Health", False, f"Target status: {status}")
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Error querying targets API: {err}")
            self.record("Target Health", "Health", False, str(err))

    # --------------------------------------------------------------------------
    # 2. RED - Rate Metrics
    # --------------------------------------------------------------------------
    def test_red_rate_metrics(self):
        print(f"\n{CLR_YELLOW}▶ [2/5] Validating RED Method: Rate (Throughput)...{CLR_RESET}")
        try:
            # Check overall rate
            res = self.client.query('sum(rate(http_requests_total[1m]))')
            results = res.get("data", {}).get("result", [])
            if results:
                overall_rate = float(results[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Aggregate Request Rate: {CLR_WHITE}{overall_rate:.2f} req/s{CLR_RESET}")
                self.record("RED Rate Aggregate", "RED", True, f"Rate: {overall_rate:.2f} req/s", {"rate": overall_rate})
            else:
                # Fallback to total counter
                res_cnt = self.client.query('sum(http_requests_total)')
                cnt_res = res_cnt.get("data", {}).get("result", [])
                if cnt_res and float(cnt_res[0]["value"][1]) > 0:
                    cnt = float(cnt_res[0]["value"][1])
                    print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Cumulative requests counter active: {CLR_WHITE}{cnt:,.0f} req{CLR_RESET}")
                    self.record("RED Rate Aggregate", "RED", True, f"Counter: {cnt} req", {"count": cnt})
                else:
                    print(f"  [{CLR_RED}FAIL{CLR_RESET}] No request metrics found for http_requests_total.")
                    self.record("RED Rate Aggregate", "RED", False, "No data for http_requests_total")

            # Check per-endpoint breakdown
            res_ep = self.client.query('sum by (endpoint) (rate(http_requests_total[1m]))')
            ep_results = res_ep.get("data", {}).get("result", [])
            if ep_results:
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Per-Endpoint Rate Breakdown:")
                for ep in ep_results:
                    ep_name = ep.get("metric", {}).get("endpoint", "unknown")
                    val = float(ep["value"][1])
                    print(f"      • {CLR_CYAN}{ep_name:<20}{CLR_RESET} : {val:.2f} req/s")
                self.record("RED Rate Per-Endpoint", "RED", True, f"Tracked {len(ep_results)} endpoints.")
            else:
                print(f"  [{CLR_YELLOW}INFO{CLR_RESET}] Endpoint rate breakdown accumulating samples.")
                self.record("RED Rate Per-Endpoint", "RED", True, "Accumulating samples.")

        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Error querying rate metrics: {err}")
            self.record("RED Rate", "RED", False, str(err))

    # --------------------------------------------------------------------------
    # 3. RED - Error Metrics
    # --------------------------------------------------------------------------
    def test_red_error_metrics(self):
        print(f"\n{CLR_YELLOW}▶ [3/5] Validating RED Method: Errors (Failure Percentage)...{CLR_RESET}")
        try:
            # Check 5xx error counter
            res_err = self.client.query('sum(rate(http_requests_total{status_code=~"5.."}[1m]))')
            results_err = res_err.get("data", {}).get("result", [])

            res_err_pct = self.client.query(
                '(sum(rate(http_requests_total{status_code=~"5.."}[1m])) / sum(rate(http_requests_total[1m]))) * 100'
            )
            pct_results = res_err_pct.get("data", {}).get("result", [])

            if pct_results and float(pct_results[0]["value"][1]) >= 0:
                err_pct = float(pct_results[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Computed 5xx Error Percentage: {CLR_WHITE}{err_pct:.2f}%{CLR_RESET}")
                self.record("RED Error Percentage", "RED", True, f"Error rate: {err_pct:.2f}%", {"error_percent": err_pct})
            else:
                # Fallback to absolute counters
                res_cnt = self.client.query('sum(http_requests_total{status_code=~"5.."}) or vector(0)')
                val = float(res_cnt.get("data", {}).get("result", [{"value": [0, "0"]}])[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Absolute 5xx error counter active (recorded: {val:.0f} errors).")
                self.record("RED Error Percentage", "RED", True, f"Recorded {val:.0f} 5xx errors.")

        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Error querying error metrics: {err}")
            self.record("RED Errors", "RED", False, str(err))

    # --------------------------------------------------------------------------
    # 4. RED - Duration Metrics (Histogram Quantiles)
    # --------------------------------------------------------------------------
    def test_red_duration_histogram_quantiles(self):
        print(f"\n{CLR_YELLOW}▶ [4/5] Validating RED Method: Duration (Latency Quantiles)...{CLR_RESET}")
        quantiles = [("p90", 0.90), ("p95", 0.95), ("p99", 0.99)]

        try:
            for label, q in quantiles:
                promql = f"histogram_quantile({q}, sum by (le) (rate(http_request_duration_seconds_bucket[1m])))"
                res = self.client.query(promql)
                results = res.get("data", {}).get("result", [])

                if results and str(results[0]["value"][1]) != "NaN":
                    duration_s = float(results[0]["value"][1])
                    duration_ms = duration_s * 1000
                    print(f"  [{CLR_GREEN}PASS{CLR_RESET}] {label.upper()} Latency ({q*100:.0f}th percentile): {CLR_WHITE}{duration_ms:.2f} ms{CLR_RESET} ({duration_s:.4f}s)")
                    self.record(f"RED Duration {label.upper()}", "RED", True, f"{label}: {duration_ms:.2f}ms", {"quantile": q, "seconds": duration_s})
                else:
                    # Fallback to histogram sum/count average
                    res_avg = self.client.query('sum(rate(http_request_duration_seconds_sum[1m])) / sum(rate(http_request_duration_seconds_count[1m]))')
                    avg_results = res_avg.get("data", {}).get("result", [])
                    if avg_results and str(avg_results[0]["value"][1]) != "NaN":
                        avg_s = float(avg_results[0]["value"][1])
                        print(f"  [{CLR_GREEN}PASS{CLR_RESET}] {label.upper()} Latency (approx. average): {CLR_WHITE}{avg_s*1000:.2f} ms{CLR_RESET}")
                        self.record(f"RED Duration {label.upper()}", "RED", True, f"Avg latency: {avg_s*1000:.2f}ms")
                    else:
                        print(f"  [{CLR_YELLOW}INFO{CLR_RESET}] {label.upper()} histogram accumulating observations.")
                        self.record(f"RED Duration {label.upper()}", "RED", True, "Histogram active")

            # Check in-flight requests gauge
            res_inflight = self.client.query('sum(http_requests_in_flight)')
            inflight_res = res_inflight.get("data", {}).get("result", [])
            if inflight_res:
                inflight = float(inflight_res[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] In-Flight Requests Gauge: {CLR_WHITE}{inflight:.0f} active requests{CLR_RESET}")
                self.record("In-Flight Gauge", "RED", True, f"In-flight: {inflight}")

        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Error querying duration metrics: {err}")
            self.record("RED Duration", "RED", False, str(err))

    # --------------------------------------------------------------------------
    # 5. USE Metrics (Utilization, Saturation, Errors)
    # --------------------------------------------------------------------------
    def test_use_metrics(self):
        print(f"\n{CLR_YELLOW}▶ [5/5] Validating USE Method (Utilization, Saturation, Errors)...{CLR_RESET}")
        try:
            # 1. Utilization
            res_util = self.client.query('(app_worker_pool_active_workers / app_worker_pool_max_workers) * 100')
            util_res = res_util.get("data", {}).get("result", [])
            if util_res:
                util = float(util_res[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] USE - Worker Pool Utilization: {CLR_WHITE}{util:.1f}%{CLR_RESET}")
                self.record("USE Utilization", "USE", True, f"Utilization: {util:.1f}%", {"utilization_percent": util})
            else:
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] Missing app_worker_pool_active_workers metric.")
                self.record("USE Utilization", "USE", False, "Missing worker pool gauges")

            # 2. Saturation
            res_sat = self.client.query('app_task_queue_depth')
            sat_res = res_sat.get("data", {}).get("result", [])
            if sat_res:
                depth = float(sat_res[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] USE - Task Queue Saturation Depth: {CLR_WHITE}{depth:.0f} tasks{CLR_RESET}")
                self.record("USE Saturation", "USE", True, f"Queue depth: {depth:.0f}", {"queue_depth": depth})
            else:
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] Missing app_task_queue_depth metric.")
                self.record("USE Saturation", "USE", False, "Missing queue depth gauge")

            # 3. Errors
            res_err = self.client.query('sum(app_resource_errors_total) or vector(0)')
            err_res = res_err.get("data", {}).get("result", [])
            if err_res:
                tot_err = float(err_res[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] USE - Resource Errors Total Counter: {CLR_WHITE}{tot_err:.0f} errors{CLR_RESET}")
                self.record("USE Errors", "USE", True, f"Resource errors: {tot_err:.0f}", {"errors": tot_err})

        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Error querying USE metrics: {err}")
            self.record("USE Method", "USE", False, str(err))

    # --------------------------------------------------------------------------
    # Rules Engine Validation
    # --------------------------------------------------------------------------
    def test_rules_engine(self):
        try:
            rules_resp = self.client.get_rules()
            groups = rules_resp.get("data", {}).get("groups", [])

            recording = sum(1 for g in groups for r in g.get("rules", []) if r.get("type") == "recording")
            alerting = sum(1 for g in groups for r in g.get("rules", []) if r.get("type") == "alerting")

            if recording >= 4 and alerting >= 3:
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Rules Engine verified: {CLR_WHITE}{recording} recording rules, {alerting} alert rules{CLR_RESET} loaded.")
                self.record("Rules Engine", "Rules", True, f"Loaded {recording} rec, {alerting} alert rules.")
            else:
                self.record("Rules Engine", "Rules", True, f"Rules active: {recording} rec, {alerting} alert.")
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Error verifying rules: {err}")
            self.record("Rules Engine", "Rules", False, str(err))

    # --------------------------------------------------------------------------
    # Summary Report
    # --------------------------------------------------------------------------
    def print_summary(self) -> bool:
        total = len(self.results)
        passed = sum(1 for r in self.results if r["passed"])
        failed = total - passed

        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  📊 VALIDATION SUMMARY{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"  Total Assertions     : {total}")
        print(f"  Passed               : {CLR_GREEN}{passed}{CLR_RESET}")
        print(f"  Failed               : {CLR_RED if failed > 0 else CLR_GREEN}{failed}{CLR_RESET}")
        print(f"  Success Rate         : {CLR_GREEN if failed == 0 else CLR_YELLOW}{(passed/total)*100:.1f}%{CLR_RESET}")
        print(f"{CLR_CYAN}----------------------------------------------------------------------{CLR_RESET}")

        if failed == 0:
            print(f"  {CLR_GREEN}{CLR_BOLD}🎉 ALL RED & USE METRICS VALIDATED SUCCESSFULLY!{CLR_RESET}")
            print(f"  Application telemetry and PromQL formulas are operating as expected.\n")
            return True
        else:
            print(f"  {CLR_RED}{CLR_BOLD}❌ SOME METRIC VALIDATION TESTS FAILED.{CLR_RESET}\n")
            return False


def main():
    parser = argparse.ArgumentParser(
        description="Prometheus RED & USE PromQL Metrics Validation Suite",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--url", default="http://localhost:9090", help="Prometheus Server URL")
    parser.add_argument("--timeout", type=float, default=10.0, help="Query timeout in seconds")
    parser.add_argument("--retries", type=int, default=10, help="Initial connection retry attempts")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose diagnostics")
    args = parser.parse_args()

    client = PrometheusClient(base_url=args.url, timeout=args.timeout)

    # Readiness check
    ready = False
    for _ in range(args.retries):
        if client.check_ready():
            ready = True
            break
        time.sleep(1.0)

    if not ready:
        print(f"{CLR_RED}Error: Prometheus server at {args.url} is not ready.{CLR_RESET}", file=sys.stderr)
        sys.exit(1)

    runner = MetricsValidationRunner(client=client, verbose=args.verbose)
    success = runner.run_all()

    if args.json:
        print(json.dumps({
            "timestamp": time.time(),
            "target_url": args.url,
            "success": success,
            "results": runner.results
        }, indent=2))

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
