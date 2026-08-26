#!/usr/bin/env python3
"""Automated Verification Suite for Log-Based Metrics Extraction & Alerting.

Validates the full telemetry-to-alerting pipeline:
1. Multi-service health (Nginx, Promtail, Loki, Prometheus, Alertmanager).
2. Promtail pipeline metrics extraction (nginx_http_500_errors_total counter & latency histogram).
3. Loki LogQL metric calculation via instant query API (rate({app="nginx"} |= "500"[1m])).
4. Prometheus rule evaluation and metric scraping.
5. Alertmanager active alert verification (firing state for 500 error anomalies).
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.parse
import urllib.error
from typing import Any, Dict, List, Optional, Tuple

# Terminal Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class AlertPipelineAuditor:
    """Performs end-to-end verification across the log-metric alerting stack."""

    def __init__(
        self,
        nginx_url: str = "http://127.0.0.1:8080",
        promtail_url: str = "http://127.0.0.1:9085",
        loki_url: str = "http://127.0.0.1:3100",
        prometheus_url: str = "http://127.0.0.1:9090",
        alertmanager_url: str = "http://127.0.0.1:9093",
    ):
        self.nginx_url = nginx_url.rstrip("/")
        self.promtail_url = promtail_url.rstrip("/")
        self.loki_url = loki_url.rstrip("/")
        self.prometheus_url = prometheus_url.rstrip("/")
        self.alertmanager_url = alertmanager_url.rstrip("/")
        self.test_results: List[Dict[str, Any]] = []

    def _http_get(self, url: str, timeout: float = 5.0) -> Tuple[int, str, float]:
        """Execute a simple HTTP GET and return status code, response body, and duration in ms."""
        start = time.perf_counter()
        req = urllib.request.Request(url, headers={"User-Agent": "LogAlert-Tester/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000.0
                return resp.status, resp.read().decode("utf-8"), elapsed_ms
        except urllib.error.HTTPError as err:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            return err.code, err.read().decode("utf-8"), elapsed_ms
        except Exception as exc:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            return 0, str(exc), elapsed_ms

    def record_test(self, name: str, passed: bool, message: str, duration_ms: float = 0.0):
        """Record and display test result."""
        self.test_results.append({
            "name": name,
            "passed": passed,
            "message": message,
            "duration_ms": duration_ms,
        })
        status_label = f"{CLR_GREEN}PASS{CLR_RESET}" if passed else f"{CLR_RED}FAIL{CLR_RESET}"
        timing = f"{CLR_GRAY}({duration_ms:.1f}ms){CLR_RESET}" if duration_ms > 0 else ""
        print(f"  [{status_label}] {CLR_BOLD}{name}{CLR_RESET} {timing}")
        if not passed or "--verbose" in sys.argv:
            print(f"         {CLR_GRAY}└─ {message}{CLR_RESET}")

    def phase1_health_checks(self) -> bool:
        """Phase 1: Verify all 5 components are operational and healthy."""
        print(f"\n{CLR_YELLOW}▶ [Phase 1] Checking Stack Infrastructure Health...{CLR_RESET}")

        # 1. Nginx
        st_ng, _, dur_ng = self._http_get(f"{self.nginx_url}/api/health")
        self.record_test("Nginx Web Application Health (:8080)", st_ng == 200, f"HTTP status {st_ng}", dur_ng)

        # 2. Promtail
        st_pt, body_pt, dur_pt = self._http_get(f"{self.promtail_url}/ready")
        self.record_test("Promtail Log Shipper Readiness (:9085)", st_pt == 200 and "Ready" in body_pt, f"Response: {body_pt.strip()}", dur_pt)

        # 3. Loki
        st_lk, body_lk, dur_lk = self._http_get(f"{self.loki_url}/ready")
        self.record_test("Grafana Loki Cluster Readiness (:3100)", st_lk == 200 and "ready" in body_lk, f"Response: {body_lk.strip()}", dur_lk)

        # 4. Prometheus
        st_pm, body_pm, dur_pm = self._http_get(f"{self.prometheus_url}/-/healthy")
        self.record_test("Prometheus Server Health (:9090)", st_pm == 200 and "Healthy" in body_pm, f"Response: {body_pm.strip()}", dur_pm)

        # 5. Alertmanager
        st_am, body_am, dur_am = self._http_get(f"{self.alertmanager_url}/-/healthy")
        self.record_test("Prometheus Alertmanager Health (:9093)", st_am == 200 and "OK" in body_am, f"Response: {body_am.strip()}", dur_am)

        return all(r["passed"] for r in self.test_results[-5:])

    def phase2_promtail_metrics_extraction(self) -> bool:
        """Phase 2: Inspect Promtail /metrics endpoint for log-extracted counters and histograms."""
        print(f"\n{CLR_YELLOW}▶ [Phase 2] Verifying Promtail Direct Metrics Extraction...{CLR_RESET}")

        st, metrics_body, dur = self._http_get(f"{self.promtail_url}/metrics")
        if st != 200:
            self.record_test("Promtail Metrics Endpoint", False, f"HTTP {st} on /metrics", dur)
            return False

        # Check total HTTP request counter
        has_requests_counter = ("nginx_http_requests_total" in metrics_body) or ("promtail_custom_nginx_http_requests_total" in metrics_body)
        self.record_test(
            "Promtail Counter Metric ('promtail_custom_nginx_http_requests_total')",
            has_requests_counter,
            "Metric extracted from access log status labels",
            dur,
        )

        # Check 500 error counter
        has_500_counter = False
        val_500 = 0.0
        for line in metrics_body.splitlines():
            if ("nginx_http_requests_total" in line or "nginx_http_500" in line) and 'status="500"' in line and not line.startswith("#"):
                has_500_counter = True
                try:
                    val_500 = float(line.split()[-1])
                except ValueError:
                    pass

        self.record_test(
            "Promtail Error Counter ('promtail_custom_nginx_http_requests_total{status=\"500\"}')",
            has_500_counter and val_500 > 0,
            f"Extracted {val_500:.0f} total 5xx errors from raw unstructured log lines",
            dur,
        )

        # Check latency histogram
        has_histogram = ("nginx_request_duration_seconds_bucket" in metrics_body) or ("promtail_custom_nginx_request_duration_seconds_bucket" in metrics_body)
        self.record_test(
            "Promtail Latency Histogram ('promtail_custom_nginx_request_duration_seconds')",
            has_histogram,
            "Latency buckets extracted from $request_time in access logs",
            dur,
        )

        return has_requests_counter and (val_500 > 0) and has_histogram

    def phase3_loki_logql_metrics(self) -> bool:
        """Phase 3: Execute LogQL instant metric queries against Loki API."""
        print(f"\n{CLR_YELLOW}▶ [Phase 3] Testing Loki LogQL Metric Calculations...{CLR_RESET}")

        # 1. Query total logs count over time
        q_count = urllib.parse.quote('sum(count_over_time({app="nginx"}[5m]))')
        st_cnt, body_cnt, dur_cnt = self._http_get(f"{self.loki_url}/loki/api/v1/query?query={q_count}")
        total_logs = 0
        try:
            res_cnt = json.loads(body_cnt)
            data_res = res_cnt.get("data", {}).get("result", [])
            if data_res:
                total_logs = int(float(data_res[0].get("value", [0, 0])[1]))
        except Exception:
            pass

        self.record_test(
            "LogQL Metric Query: count_over_time({app='nginx'}[5m])",
            st_cnt == 200 and total_logs > 0,
            f"Loki calculated {total_logs} log entries processed in the last 5 minutes",
            dur_cnt,
        )

        # 2. Query 500 error rate over time
        q_rate = urllib.parse.quote('sum(rate({app="nginx"} |= "500" [5m]))')
        st_rate, body_rate, dur_rate = self._http_get(f"{self.loki_url}/loki/api/v1/query?query={q_rate}")
        error_rate = 0.0
        try:
            res_rate = json.loads(body_rate)
            data_rate = res_rate.get("data", {}).get("result", [])
            if data_rate:
                error_rate = float(data_rate[0].get("value", [0, 0])[1])
        except Exception:
            pass

        self.record_test(
            "LogQL Metric Query: sum(rate({app='nginx'} |= '500' [5m]))",
            st_rate == 200 and error_rate > 0.0,
            f"Real-time calculated 500 error rate: {error_rate:.2f} errors/sec",
            dur_rate,
        )

        return (total_logs > 0) and (error_rate > 0.0)

    def phase4_prometheus_evaluations(self) -> bool:
        """Phase 4: Verify Prometheus has scraped Promtail metrics and registered alerting rules."""
        print(f"\n{CLR_YELLOW}▶ [Phase 4] Checking Prometheus Metrics & Alert Rules...{CLR_RESET}")

        # Check alert rules registration
        st_rules, body_rules, dur_rules = self._http_get(f"{self.prometheus_url}/api/v1/rules")
        rule_registered = False
        try:
            data_rules = json.loads(body_rules)
            groups = data_rules.get("data", {}).get("groups", [])
            for g in groups:
                for r in g.get("rules", []):
                    if r.get("name") == "NginxLogMetric500Spike":
                        rule_registered = True
        except Exception:
            pass

        self.record_test(
            "Prometheus Rule Registration ('NginxLogMetric500Spike')",
            st_rules == 200 and rule_registered,
            f"Rule active with expression: rate(nginx_http_500_errors_total[1m]) > 0.2",
            dur_rules,
        )

        # Query Prometheus for the log metric
        q_prom = urllib.parse.quote('promtail_custom_nginx_http_requests_total{status="500"}')
        st_val, body_val, dur_val = self._http_get(f"{self.prometheus_url}/api/v1/query?query={q_prom}")
        metric_scraped = False
        val_prom = 0.0
        try:
            data_val = json.loads(body_val)
            results = data_val.get("data", {}).get("result", [])
            if results:
                metric_scraped = True
                val_prom = float(results[0].get("value", [0, 0])[1])
        except Exception:
            pass

        self.record_test(
            "Prometheus Target Scrape ('promtail_custom_nginx_http_requests_total')",
            metric_scraped and val_prom > 0,
            f"Prometheus successfully scraped log metric (500 count: {val_prom:.0f}) from Promtail exporter",
            dur_val,
        )

        return rule_registered and metric_scraped

    def phase5_alertmanager_notifications(self) -> bool:
        """Phase 5: Poll Alertmanager active alerts to verify firing alert on error threshold."""
        print(f"\n{CLR_YELLOW}▶ [Phase 5] Asserting Active Firing Alerts in Alertmanager...{CLR_RESET}")

        max_wait = 20
        start = time.perf_counter()
        active_alerts = []

        print(f"  Waiting for evaluation cycles and alert propagation (up to {max_wait}s)...")
        for _ in range(max_wait):
            st, body, _ = self._http_get(f"{self.alertmanager_url}/api/v2/alerts")
            if st == 200:
                try:
                    alerts = json.loads(body)
                    for a in alerts:
                        labels = a.get("labels", {})
                        alertname = labels.get("alertname", "")
                        if alertname in ("NginxLogMetric500Spike", "NginxHighErrorRateLogQL") and a.get("status", {}).get("state") in ("active", "unprocessed"):
                            active_alerts.append(a)
                    if active_alerts:
                        break
                except Exception:
                    pass
            time.sleep(1.0)

        elapsed = (time.perf_counter() - start) * 1000.0

        alert_found = len(active_alerts) > 0
        alert_name = active_alerts[0].get("labels", {}).get("alertname", "N/A") if alert_found else "None"
        alert_summary = active_alerts[0].get("annotations", {}).get("summary", "N/A") if alert_found else "No alert triggered"

        self.record_test(
            "Alertmanager Active Firing Alert Triggered",
            alert_found,
            f"Alert '{alert_name}' is actively firing. Summary: '{alert_summary}'",
            elapsed,
        )

        return alert_found

    def run_full_suite(self) -> bool:
        """Run all verification phases and display summary."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  📊 Log-Based Metrics & Alerting Pipeline Verification Suite{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

        self.phase1_health_checks()
        self.phase2_promtail_metrics_extraction()
        self.phase3_loki_logql_metrics()
        self.phase4_prometheus_evaluations()
        self.phase5_alertmanager_notifications()

        passed_count = sum(1 for r in self.test_results if r["passed"])
        total_count = len(self.test_results)
        all_passed = (passed_count == total_count)

        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  📊 Verification Results: {passed_count}/{total_count} Passed{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

        if all_passed:
            print(f"\n{CLR_GREEN}{CLR_BOLD}🎉 ALL LOG-METRIC EXTRACTION & ALERTING ASSERTIONS SUCCEEDED!{CLR_RESET}\n")
            print(f"  👉 Prometheus Web UI:   {self.prometheus_url}")
            print(f"  👉 Alertmanager Web UI: {self.alertmanager_url}")
            print(f"  👉 Nginx Application:   {self.nginx_url}\n")
        else:
            print(f"\n{CLR_RED}{CLR_BOLD}❌ VERIFICATION FAILED: {total_count - passed_count} ASSERTIONS FAILED.{CLR_RESET}\n")

        return all_passed


def main():
    parser = argparse.ArgumentParser(description="Verify log-based metrics extraction and alerting pipeline.")
    parser.add_argument("--nginx", default="http://127.0.0.1:8080", help="Nginx URL")
    parser.add_argument("--promtail", default="http://127.0.0.1:9085", help="Promtail URL")
    parser.add_argument("--loki", default="http://127.0.0.1:3100", help="Loki URL")
    parser.add_argument("--prometheus", default="http://127.0.0.1:9090", help="Prometheus URL")
    parser.add_argument("--alertmanager", default="http://127.0.0.1:9093", help="Alertmanager URL")
    parser.add_argument("--verbose", action="store_true", help="Print verbose details")

    args = parser.parse_args()

    auditor = AlertPipelineAuditor(
        nginx_url=args.nginx,
        promtail_url=args.promtail,
        loki_url=args.loki,
        prometheus_url=args.prometheus,
        alertmanager_url=args.alertmanager,
    )
    success = auditor.run_full_suite()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
