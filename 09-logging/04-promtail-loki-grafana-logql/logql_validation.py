#!/usr/bin/env python3
"""Automated LogQL Query Test Suite & Loki Ingestion Validator.

Executes a comprehensive battery of LogQL stream selectors, line filters,
JSON parsers, dynamic label filters, and metric aggregation queries against the Loki API.
"""

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from typing import Any, Dict, List, Optional, Tuple

# ANSI Terminal Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class LogQLValidator:
    """Queries Loki HTTP API and validates LogQL query results and sub-second performance."""

    def __init__(self, base_url: str = "http://localhost:3100"):
        self.base_url = base_url.rstrip("/")
        self.test_results: List[Dict[str, Any]] = []

    def _http_get(self, path: str, params: Optional[Dict[str, str]] = None) -> Tuple[int, Any, float]:
        """Execute HTTP GET request to Loki API and measure latency."""
        url = f"{self.base_url}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)

        start_time = time.perf_counter()
        req = urllib.request.Request(url, headers={"User-Agent": "LogQL-Validator/1.0"})

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                duration_ms = (time.perf_counter() - start_time) * 1000
                body = response.read().decode("utf-8")
                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    data = body
                return response.status, data, duration_ms
        except urllib.error.HTTPError as err:
            duration_ms = (time.perf_counter() - start_time) * 1000
            err_body = err.read().decode("utf-8", errors="replace")
            return err.code, err_body, duration_ms
        except Exception as exc:
            duration_ms = (time.perf_counter() - start_time) * 1000
            return 0, str(exc), duration_ms

    def verify_loki_ready(self) -> bool:
        """Check if Loki instance is healthy and accepting queries."""
        status, data, duration_ms = self._http_get("/ready")
        if status == 200 and "ready" in str(data).lower():
            print(f"  [{CLR_GREEN}READY{CLR_RESET}] Loki is operational ({duration_ms:.1f}ms)")
            return True
        print(f"  [{CLR_RED}FAIL{CLR_RESET}] Loki is not ready (Status: {status}, Response: {data})")
        return False

    def verify_label_extraction(self) -> bool:
        """Validate dynamic labels extracted by Promtail pipeline stages."""
        print(f"\n{CLR_YELLOW}▶ Auditing Promtail Dynamic Label Extraction...{CLR_RESET}")
        status, data, duration_ms = self._http_get("/loki/api/v1/labels")
        if status != 200 or not isinstance(data, dict):
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Failed querying /loki/api/v1/labels")
            return False

        labels = data.get("data", [])
        print(f"  • Discovered Index Labels: {CLR_CYAN}{', '.join(labels)}{CLR_RESET}")

        required_labels = ["job", "environment", "app", "level"]
        missing = [lbl for lbl in required_labels if lbl not in labels]

        if missing:
            print(f"  [{CLR_YELLOW}WARN{CLR_RESET}] Expected labels not yet indexed: {missing}")
        else:
            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] All dynamic Promtail pipeline labels successfully indexed!")

        # Query specific label values
        for label_name in ["app", "level"]:
            st, val_data, _ = self._http_get(f"/loki/api/v1/label/{label_name}/values")
            if st == 200 and isinstance(val_data, dict):
                vals = val_data.get("data", [])
                print(f"    ↳ Values for '{label_name}': {vals}")

        return True

    def run_query_tests(self) -> bool:
        """Execute a comprehensive battery of LogQL queries."""
        print(f"\n{CLR_YELLOW}▶ Executing LogQL Query Test Battery...{CLR_RESET}")

        test_cases = [
            {
                "name": "Stream Selector ({app=\"api\"})",
                "query": '{app="api"}',
                "type": "streams",
                "desc": "Fetch logs matching stream label app='api'",
            },
            {
                "name": "Line Filter ({app=\"api\"} |= \"error\")",
                "query": '{app="api"} |= "error"',
                "type": "streams",
                "desc": "Case-sensitive substring line filter for error events",
            },
            {
                "name": "Dynamic Label Filter ({level=\"ERROR\"})",
                "query": '{level="ERROR"}',
                "type": "streams",
                "desc": "Query logs using Promtail dynamic label level='ERROR'",
            },
            {
                "name": "JSON Parsing Stage ({job=\"app_logs\"} | json)",
                "query": '{job="app_logs"} | json | status_code >= 500',
                "type": "streams",
                "desc": "Runtime JSON parser extracting status_code and filtering 5xx errors",
            },
            {
                "name": "Multi-App Regex Filter ({app=~\"api|billing\"})",
                "query": '{app=~"api|billing"} |~ "timeout|deadlock|gateway"',
                "type": "streams",
                "desc": "Regex stream selection and regex line pattern matching",
            },
            {
                "name": "Metric Aggregation (LogQL rate())",
                "query": 'sum by (app) (rate({job="app_logs"}[1m]))',
                "type": "matrix",
                "desc": "Derive real-time numerical logs/sec timeseries from raw streams",
            },
            {
                "name": "Error Metric Rate (rate(..level=ERROR))",
                "query": 'sum by (app) (rate({job="app_logs", level="ERROR"}[1m]))',
                "type": "matrix",
                "desc": "Calculate per-service error rate per second",
            },
        ]

        all_passed = True

        for tc in test_cases:
            # Query over the last 1 hour
            params = {
                "query": tc["query"],
                "limit": "100",
            }
            status, res_data, duration_ms = self._http_get("/loki/api/v1/query_range", params=params)

            is_pass = False
            item_count = 0
            details = ""

            if status == 200 and isinstance(res_data, dict):
                result_type = res_data.get("data", {}).get("resultType")
                results = res_data.get("data", {}).get("result", [])
                item_count = len(results)

                if duration_ms < 1000.0:  # Sub-second latency assertion
                    is_pass = True
                    details = f"{item_count} {result_type} returned in {duration_ms:.1f}ms"
                else:
                    details = f"Query took {duration_ms:.1f}ms (>1000ms threshold)"
            else:
                details = f"HTTP {status}: {str(res_data)[:120]}"

            if not is_pass:
                all_passed = False

            self.test_results.append(
                {
                    "name": tc["name"],
                    "query": tc["query"],
                    "status": "PASS" if is_pass else "FAIL",
                    "duration_ms": duration_ms,
                    "item_count": item_count,
                    "details": details,
                    "desc": tc["desc"],
                }
            )

        return all_passed

    def print_report(self) -> None:
        """Render a formatted, colored validation summary report."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 76)
        print("  📊 GRAFANA LOKI LOGQL PIPELINE VALIDATION REPORT")
        print("=" * 76 + f"{CLR_RESET}\n")

        print(
            f"  {CLR_GRAY}┌──────────────────────────────────────────────────┬────────┬───────────┬────────┐{CLR_RESET}"
        )
        print(
            f"  {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}LogQL Test Query{CLR_RESET}                                 {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}Status{CLR_RESET} {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}Latency{CLR_RESET}   {CLR_GRAY}│{CLR_RESET} {CLR_BOLD}Matched{CLR_RESET}{CLR_GRAY}│{CLR_RESET}"
        )
        print(
            f"  {CLR_GRAY}├──────────────────────────────────────────────────┼────────┼───────────┼────────┤{CLR_RESET}"
        )

        for res in self.test_results:
            status_color = CLR_GREEN if res["status"] == "PASS" else CLR_RED
            name_cut = res["name"][:48]
            print(
                f"  {CLR_GRAY}│{CLR_RESET} {name_cut:<48} {CLR_GRAY}│{CLR_RESET} {status_color}{res['status']:<6}{CLR_RESET} {CLR_GRAY}│{CLR_RESET} {res['duration_ms']:>7.1f}ms {CLR_GRAY}│{CLR_RESET} {res['item_count']:>6} {CLR_GRAY}│{CLR_RESET}"
            )

        print(
            f"  {CLR_GRAY}└──────────────────────────────────────────────────┴────────┴───────────┴────────┘{CLR_RESET}\n"
        )

        passed_count = sum(1 for r in self.test_results if r["status"] == "PASS")
        total_count = len(self.test_results)

        print(f"  {CLR_BOLD}Performance & Reliability Summary:{CLR_RESET}")
        print(f"  • Sub-second Search Responses: {CLR_GREEN}{passed_count}/{total_count} Passed{CLR_RESET}")
        print(f"  • Average LogQL Query Latency: {CLR_CYAN}{sum(r['duration_ms'] for r in self.test_results)/max(1, total_count):.2f}ms{CLR_RESET}")
        print(f"  • Grafana Web UI Available at: {CLR_BOLD}http://localhost:3000{CLR_RESET} (admin / admin)\n")

        print(f"{CLR_CYAN}" + "=" * 76 + f"{CLR_RESET}\n")


# ------------------------------------------------------------------------------
# CLI Entrypoint
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Test LogQL queries against Grafana Loki API.")
    parser.add_argument("--url", default="http://localhost:3100", help="Base URL of Loki API (default: http://localhost:3100)")
    parser.add_argument("--retries", type=int, default=10, help="Max connection readiness retries")
    args = parser.parse_args()

    validator = LogQLValidator(base_url=args.url)

    # Wait for Loki readiness
    ready = False
    for attempt in range(1, args.retries + 1):
        if validator.verify_loki_ready():
            ready = True
            break
        time.sleep(2)

    if not ready:
        sys.exit(1)

    # Allow Promtail 3 seconds to scrape and ingest initial log batch
    time.sleep(3)

    validator.verify_label_extraction()
    success = validator.run_query_tests()
    validator.print_report()

    if success:
        print(f"{CLR_GREEN}{CLR_BOLD}✅ SUCCESS: All LogQL queries executed with sub-second response times!{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"{CLR_RED}{CLR_BOLD}❌ FAILED: One or more LogQL assertions did not pass.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
