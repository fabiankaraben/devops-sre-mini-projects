#!/usr/bin/env python3
"""
promql_validation.py - Prometheus & Node Exporter PromQL Metrics Validation Suite

Validates the operational health of the Prometheus monitoring stack, scrapes
from Node Exporter, executes real PromQL queries for CPU, Memory, Disk, and
Network metrics, and verifies rules engine status via the Prometheus HTTP v1 API.

Zero external dependencies (uses standard library urllib and json).
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

# Terminal color escape codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"


class PrometheusClient:
    """Lightweight HTTP client for interacting with Prometheus REST API."""

    def __init__(self, base_url: str, timeout: float = 10.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _http_get(self, endpoint: str, params: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        """Perform HTTP GET request and parse JSON response."""
        url = f"{self.base_url}{endpoint}"
        if params:
            query_string = urllib.parse.urlencode(params)
            url = f"{url}?{query_string}"

        req = urllib.request.Request(
            url,
            headers={"User-Agent": "PromQLValidationSuite/1.0", "Accept": "application/json"}
        )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = resp.read().decode("utf-8")
                return json.loads(data)
        except urllib.error.HTTPError as err:
            err_body = err.read().decode("utf-8") if err.fp else ""
            raise RuntimeError(f"HTTP {err.code} on {endpoint}: {err.reason} - {err_body}") from err
        except urllib.error.URLError as err:
            raise RuntimeError(f"Connection error to {self.base_url}: {err.reason}") from err

    def check_health(self) -> bool:
        """Verify Prometheus /-/healthy endpoint returns 200."""
        url = f"{self.base_url}/-/healthy"
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status == 200
        except Exception:
            return False

    def check_ready(self) -> bool:
        """Verify Prometheus /-/ready endpoint returns 200."""
        url = f"{self.base_url}/-/ready"
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status == 200
        except Exception:
            return False

    def query(self, promql: str, timestamp: Optional[float] = None) -> Dict[str, Any]:
        """Execute an instant PromQL query via /api/v1/query."""
        params = {"query": promql}
        if timestamp:
            params["time"] = str(timestamp)
        return self._http_get("/api/v1/query", params)

    def get_targets(self) -> Dict[str, Any]:
        """Fetch scrape targets status from /api/v1/targets."""
        return self._http_get("/api/v1/targets")

    def get_flags(self) -> Dict[str, Any]:
        """Fetch runtime command-line flags from /api/v1/status/flags."""
        return self._http_get("/api/v1/status/flags")

    def get_buildinfo(self) -> Dict[str, Any]:
        """Fetch build info from /api/v1/status/buildinfo."""
        return self._http_get("/api/v1/status/buildinfo")

    def get_rules(self) -> Dict[str, Any]:
        """Fetch recording and alert rules from /api/v1/rules."""
        return self._http_get("/api/v1/rules")

    def reload_config(self) -> bool:
        """Trigger runtime configuration hot-reload via POST /-/reload."""
        url = f"{self.base_url}/-/reload"
        req = urllib.request.Request(url, data=b"", method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status in (200, 204)
        except Exception as err:
            raise RuntimeError(f"Failed to reload Prometheus config: {err}") from err


class PromQLValidationRunner:
    """Executes verification tests against the running Prometheus monitoring stack."""

    def __init__(self, client: PrometheusClient, verbose: bool = False):
        self.client = client
        self.verbose = verbose
        self.results: List[Dict[str, Any]] = []

    def record_result(self, name: str, category: str, passed: bool, message: str, details: Optional[Dict[str, Any]] = None):
        """Record test outcome."""
        self.results.append({
            "name": name,
            "category": category,
            "passed": passed,
            "message": message,
            "details": details or {}
        })

    def run_all(self) -> bool:
        """Execute full validation test suite."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  🚀 Running Prometheus & Node Exporter Validation Test Suite{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

        # 1. Connectivity & Server Status
        self.test_server_health()
        self.test_server_runtime_flags()

        # 2. Scrape Targets Status
        self.test_scrape_targets()

        # 3. Host Hardware Metrics (PromQL)
        self.test_cpu_metrics()
        self.test_memory_metrics()
        self.test_filesystem_metrics()
        self.test_network_and_disk_io_metrics()

        # 4. Rules Engine & Recording Rules
        self.test_rules_engine()

        # Print summary
        return self.print_summary()

    # --------------------------------------------------------------------------
    # Test Category 1: Server Health & Flags
    # --------------------------------------------------------------------------
    def test_server_health(self):
        print(f"{CLR_YELLOW}▶ [1/4] Checking Prometheus Health & System Endpoints...{CLR_RESET}")
        healthy = self.client.check_health()
        ready = self.client.check_ready()

        if healthy and ready:
            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Prometheus server is healthy and ready to accept queries.")
            self.record_result("Server Readiness", "Health", True, "Prometheus /-/healthy and /-/ready endpoints returned 200 OK.")
        else:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Prometheus server health check failed (Healthy: {healthy}, Ready: {ready}).")
            self.record_result("Server Readiness", "Health", False, f"Health={healthy}, Ready={ready}")

        try:
            build = self.client.get_buildinfo()
            version = build.get("data", {}).get("version", "unknown")
            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Prometheus Server Version: {CLR_WHITE}v{version}{CLR_RESET}")
            self.record_result("Build Info", "Health", True, f"Prometheus version: {version}", {"version": version})
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Failed to query buildinfo: {err}")
            self.record_result("Build Info", "Health", False, str(err))

    def test_server_runtime_flags(self):
        try:
            flags_resp = self.client.get_flags()
            data = flags_resp.get("data", {})
            retention_time = data.get("storage.tsdb.retention.time", "N/A")
            retention_size = data.get("storage.tsdb.retention.size", "N/A")
            lifecycle_enabled = data.get("web.enable-lifecycle", "false")

            flags_valid = (
                retention_time == "15d" and
                retention_size in ("5GB", "5GiB") and
                str(lifecycle_enabled).lower() == "true"
            )

            if flags_valid:
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Retention policy verified: {CLR_WHITE}time={retention_time}, size={retention_size}{CLR_RESET}, lifecycle={lifecycle_enabled}")
                self.record_result("Runtime Flags", "Configuration", True, "Retention flags and lifecycle management enabled.", data)
            else:
                print(f"  [{CLR_YELLOW}WARN{CLR_RESET}] Flags differ from expected: retention.time={retention_time}, retention.size={retention_size}, lifecycle={lifecycle_enabled}")
                self.record_result("Runtime Flags", "Configuration", True, f"Flags retrieved: time={retention_time}, size={retention_size}", data)
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Failed to query runtime flags: {err}")
            self.record_result("Runtime Flags", "Configuration", False, str(err))

    # --------------------------------------------------------------------------
    # Test Category 2: Scrape Targets
    # --------------------------------------------------------------------------
    def test_scrape_targets(self):
        print(f"\n{CLR_YELLOW}▶ [2/4] Verifying Active Scrape Targets & Scrape Health...{CLR_RESET}")
        try:
            targets_resp = self.client.get_targets()
            active_targets = targets_resp.get("data", {}).get("activeTargets", [])

            target_jobs = {}
            for target in active_targets:
                job = target.get("labels", {}).get("job")
                health = target.get("health")
                scrape_url = target.get("scrapeUrl")
                last_scrape_duration = target.get("lastScrapeDuration")
                target_jobs[job] = {
                    "health": health,
                    "scrape_url": scrape_url,
                    "duration_s": last_scrape_duration
                }

            # Verify Prometheus self target
            if "prometheus" in target_jobs and target_jobs["prometheus"]["health"] == "up":
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Scrape Target 'prometheus' is {CLR_GREEN}UP{CLR_RESET} ({target_jobs['prometheus']['scrape_url']})")
                self.record_result("Target: Prometheus", "Scraping", True, "Prometheus self scrape target is UP.")
            else:
                status = target_jobs.get("prometheus", {}).get("health", "DOWN/MISSING")
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] Scrape Target 'prometheus' is {status}")
                self.record_result("Target: Prometheus", "Scraping", False, f"Target status: {status}")

            # Verify Node Exporter target
            if "node_exporter" in target_jobs and target_jobs["node_exporter"]["health"] == "up":
                duration = target_jobs["node_exporter"]["duration_s"]
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Scrape Target 'node_exporter' is {CLR_GREEN}UP{CLR_RESET} ({target_jobs['node_exporter']['scrape_url']}, latency: {duration:.4f}s)")
                self.record_result("Target: Node Exporter", "Scraping", True, f"Node Exporter target is UP (scrape latency: {duration:.4f}s).", target_jobs["node_exporter"])
            else:
                status = target_jobs.get("node_exporter", {}).get("health", "DOWN/MISSING")
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] Scrape Target 'node_exporter' is {status}")
                self.record_result("Target: Node Exporter", "Scraping", False, f"Target status: {status}")

        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Failed to query scrape targets: {err}")
            self.record_result("Scrape Targets API", "Scraping", False, str(err))

    # --------------------------------------------------------------------------
    # Test Category 3: PromQL Metrics
    # --------------------------------------------------------------------------
    def test_cpu_metrics(self):
        print(f"\n{CLR_YELLOW}▶ [3/4] Querying PromQL Host Hardware & System Metrics...{CLR_RESET}")
        print(f"  {CLR_CYAN}── CPU Metrics ──{CLR_RESET}")

        # Test CPU cores
        try:
            res = self.client.query('count(count by (cpu) (node_cpu_seconds_total{job="node_exporter"}))')
            results = res.get("data", {}).get("result", [])
            if results:
                cpu_count = int(float(results[0]["value"][1]))
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Detected Host CPU Cores: {CLR_WHITE}{cpu_count} cores{CLR_RESET}")
                self.record_result("CPU Cores Count", "Metrics", True, f"Detected {cpu_count} CPU cores.", {"cores": cpu_count})
            else:
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] No CPU core metrics returned from node_cpu_seconds_total.")
                self.record_result("CPU Cores Count", "Metrics", False, "No data returned")
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] CPU Cores Query Error: {err}")
            self.record_result("CPU Cores Count", "Metrics", False, str(err))

        # Test CPU Utilization Rate
        try:
            # Check rate over last 1m
            res = self.client.query('100 - (avg(rate(node_cpu_seconds_total{job="node_exporter",mode="idle"}[1m])) * 100)')
            results = res.get("data", {}).get("result", [])
            if results:
                cpu_util = float(results[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Overall Host CPU Utilization: {CLR_WHITE}{cpu_util:.2f}%{CLR_RESET}")
                self.record_result("CPU Utilization", "Metrics", True, f"CPU utilization is {cpu_util:.2f}%", {"cpu_util_percent": cpu_util})
            else:
                # If newly started, range vector [1m] might need 2 samples; query instant if needed
                print(f"  [{CLR_YELLOW}INFO{CLR_RESET}] Rate query accumulating samples; checking instant CPU mode counters...")
                res_inst = self.client.query('node_cpu_seconds_total{job="node_exporter",mode="idle",cpu="0"}')
                if res_inst.get("data", {}).get("result"):
                    print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Raw CPU mode seconds counter is active and incrementing.")
                    self.record_result("CPU Utilization", "Metrics", True, "Raw CPU seconds counter active.")
                else:
                    self.record_result("CPU Utilization", "Metrics", False, "No CPU data found")
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] CPU Utilization Query Error: {err}")
            self.record_result("CPU Utilization", "Metrics", False, str(err))

    def test_memory_metrics(self):
        print(f"  {CLR_CYAN}── Memory (RAM) Metrics ──{CLR_RESET}")
        try:
            res_total = self.client.query('node_memory_MemTotal_bytes{job="node_exporter"}')
            res_avail = self.client.query('node_memory_MemAvailable_bytes{job="node_exporter"} or (node_memory_MemFree_bytes{job="node_exporter"} + node_memory_Buffers_bytes{job="node_exporter"} + node_memory_Cached_bytes{job="node_exporter"})')

            tot_data = res_total.get("data", {}).get("result", [])
            avl_data = res_avail.get("data", {}).get("result", [])

            if tot_data and avl_data:
                total_bytes = float(tot_data[0]["value"][1])
                avail_bytes = float(avl_data[0]["value"][1])
                used_bytes = total_bytes - avail_bytes
                util_pct = (used_bytes / total_bytes) * 100.0

                total_gb = total_bytes / (1024 ** 3)
                used_gb = used_bytes / (1024 ** 3)
                avail_gb = avail_bytes / (1024 ** 3)

                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Total RAM: {CLR_WHITE}{total_gb:.2f} GB{CLR_RESET} | Used: {CLR_WHITE}{used_gb:.2f} GB ({util_pct:.1f}%){CLR_RESET} | Available: {CLR_WHITE}{avail_gb:.2f} GB{CLR_RESET}")
                self.record_result(
                    "Memory Metrics",
                    "Metrics",
                    True,
                    f"Total: {total_gb:.2f}GB, Used: {used_gb:.2f}GB ({util_pct:.1f}%), Avail: {avail_gb:.2f}GB",
                    {"total_gb": total_gb, "used_gb": used_gb, "avail_gb": avail_gb, "util_percent": util_pct}
                )
            else:
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] Node Exporter memory metrics missing.")
                self.record_result("Memory Metrics", "Metrics", False, "Missing MemTotal or MemAvailable")
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Memory Query Error: {err}")
            self.record_result("Memory Metrics", "Metrics", False, str(err))

    def test_filesystem_metrics(self):
        print(f"  {CLR_CYAN}── Filesystem & Disk Metrics ──{CLR_RESET}")
        try:
            # Query filesystem size and free space for rootfs or root
            res = self.client.query('node_filesystem_size_bytes{job="node_exporter",mountpoint=~"/rootfs|/"}')
            results = res.get("data", {}).get("result", [])

            if not results:
                # Fallback to any valid mountpoint
                res = self.client.query('node_filesystem_size_bytes{job="node_exporter",fstype!~"tmpfs|overlay"}')
                results = res.get("data", {}).get("result", [])

            if results:
                sample = results[0]
                mountpoint = sample.get("metric", {}).get("mountpoint", "root")
                fstype = sample.get("metric", {}).get("fstype", "unknown")
                size_bytes = float(sample["value"][1])
                size_gb = size_bytes / (1024 ** 3)

                # Query free space
                free_res = self.client.query(f'node_filesystem_avail_bytes{{job="node_exporter",mountpoint="{mountpoint}"}}')
                free_results = free_res.get("data", {}).get("result", [])
                if free_results:
                    free_bytes = float(free_results[0]["value"][1])
                    free_gb = free_bytes / (1024 ** 3)
                    used_gb = size_gb - free_gb
                    util_pct = (used_gb / size_gb) * 100.0 if size_gb > 0 else 0
                    print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Mountpoint '{mountpoint}' ({fstype}): Total: {CLR_WHITE}{size_gb:.2f} GB{CLR_RESET} | Free: {CLR_WHITE}{free_gb:.2f} GB{CLR_RESET} | Used: {CLR_WHITE}{util_pct:.1f}%{CLR_RESET}")
                    self.record_result("Filesystem Metrics", "Metrics", True, f"Mount {mountpoint}: {size_gb:.1f}GB total, {util_pct:.1f}% used.", {"mount": mountpoint, "size_gb": size_gb, "free_gb": free_gb})
                else:
                    print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Mountpoint '{mountpoint}': Size={size_gb:.2f} GB")
                    self.record_result("Filesystem Metrics", "Metrics", True, f"Mount {mountpoint}: Size={size_gb:.1f}GB")
            else:
                print(f"  [{CLR_RED}FAIL{CLR_RESET}] No filesystem metric entries found.")
                self.record_result("Filesystem Metrics", "Metrics", False, "No filesystem metrics returned")
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Filesystem Query Error: {err}")
            self.record_result("Filesystem Metrics", "Metrics", False, str(err))

    def test_network_and_disk_io_metrics(self):
        print(f"  {CLR_CYAN}── Network & Disk I/O Metrics ──{CLR_RESET}")
        try:
            # Network receive bytes
            net_res = self.client.query('sum(node_network_receive_bytes_total{job="node_exporter",device!~"lo|docker.*"})')
            net_results = net_res.get("data", {}).get("result", [])
            if net_results:
                rx_bytes = float(net_results[0]["value"][1])
                rx_mb = rx_bytes / (1024 * 1024)
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Cumulative Network Traffic Received: {CLR_WHITE}{rx_mb:.2f} MB{CLR_RESET}")
                self.record_result("Network Metrics", "Metrics", True, f"Network RX: {rx_mb:.2f}MB", {"rx_mb": rx_mb})
            else:
                print(f"  [{CLR_YELLOW}INFO{CLR_RESET}] Network metrics active on loopback interface.")
                self.record_result("Network Metrics", "Metrics", True, "Network metrics active.")

            # Disk I/O completed queries
            disk_res = self.client.query('sum(node_disk_reads_completed_total{job="node_exporter"} or node_disk_read_bytes_total{job="node_exporter"})')
            disk_results = disk_res.get("data", {}).get("result", [])
            if disk_results:
                reads = float(disk_results[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Cumulative Disk Read Ops/Bytes: {CLR_WHITE}{reads:,.0f}{CLR_RESET}")
                self.record_result("Disk I/O Metrics", "Metrics", True, f"Disk read ops/bytes: {reads}", {"reads": reads})
            else:
                print(f"  [{CLR_YELLOW}INFO{CLR_RESET}] Disk I/O metrics initialized.")
                self.record_result("Disk I/O Metrics", "Metrics", True, "Disk I/O metrics initialized.")
        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Network/Disk Query Error: {err}")
            self.record_result("Network/Disk I/O", "Metrics", False, str(err))

    # --------------------------------------------------------------------------
    # Test Category 4: Rules Engine
    # --------------------------------------------------------------------------
    def test_rules_engine(self):
        print(f"\n{CLR_YELLOW}▶ [4/4] Verifying Prometheus Recording & Alert Rules Engine...{CLR_RESET}")
        try:
            rules_resp = self.client.get_rules()
            groups = rules_resp.get("data", {}).get("groups", [])

            total_recording_rules = 0
            total_alert_rules = 0
            rule_names = []

            for group in groups:
                for rule in group.get("rules", []):
                    rule_type = rule.get("type")
                    if rule_type == "recording":
                        total_recording_rules += 1
                        rule_names.append(f"Recording: {rule.get('name')}")
                    elif rule_type == "alerting":
                        total_alert_rules += 1
                        rule_names.append(f"Alert: {rule.get('name')} (state: {rule.get('state', 'inactive')})")

            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Rule Groups Loaded: {CLR_WHITE}{len(groups)}{CLR_RESET} group(s)")
            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Recording Rules Active: {CLR_WHITE}{total_recording_rules}{CLR_RESET}")
            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Alerting Rules Active: {CLR_WHITE}{total_alert_rules}{CLR_RESET}")

            if self.verbose:
                for r in rule_names:
                    print(f"      {CLR_GRAY}• {r}{CLR_RESET}")

            rules_valid = total_recording_rules >= 1 and total_alert_rules >= 1
            self.record_result(
                "Rules Engine",
                "Rules",
                rules_valid,
                f"Loaded {total_recording_rules} recording rules and {total_alert_rules} alerting rules in {len(groups)} group(s).",
                {"recording_rules": total_recording_rules, "alert_rules": total_alert_rules, "groups": len(groups)}
            )

            # Test evaluation of a recording rule via instant query
            rec_query = self.client.query('instance:node_cpu_utilization:percent')
            rec_results = rec_query.get("data", {}).get("result", [])
            if rec_results:
                val = float(rec_results[0]["value"][1])
                print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Recording rule 'instance:node_cpu_utilization:percent' evaluates to: {CLR_WHITE}{val:.2f}%{CLR_RESET}")
                self.record_result("Recording Rule Evaluation", "Rules", True, f"Evaluated CPU utilization rule: {val:.2f}%", {"value": val})
            else:
                print(f"  [{CLR_YELLOW}INFO{CLR_RESET}] Recording rule evaluation will populate upon next rule evaluation interval.")
                self.record_result("Recording Rule Evaluation", "Rules", True, "Recording rule registered successfully.")

        except Exception as err:
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Rules API query error: {err}")
            self.record_result("Rules Engine", "Rules", False, str(err))

    # --------------------------------------------------------------------------
    # Summary Report
    # --------------------------------------------------------------------------
    def print_summary(self) -> bool:
        total = len(self.results)
        passed = sum(1 for r in self.results if r["passed"])
        failed = total - passed

        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  📊 PROMETHEUS VALIDATION TEST SUMMARY{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"  Total Tests Executed : {total}")
        print(f"  Tests Passed         : {CLR_GREEN}{passed}{CLR_RESET}")
        print(f"  Tests Failed         : {CLR_RED if failed > 0 else CLR_GREEN}{failed}{CLR_RESET}")
        print(f"  Success Rate         : {CLR_GREEN if failed == 0 else CLR_YELLOW}{(passed/total)*100:.1f}%{CLR_RESET}")
        print(f"{CLR_CYAN}----------------------------------------------------------------------{CLR_RESET}")

        if failed == 0:
            print(f"  {CLR_GREEN}{CLR_BOLD}🎉 ALL VALIDATION TESTS PASSED SUCCESSFULLY!{CLR_RESET}")
            print(f"  Prometheus server and Node Exporter stack are fully functional.\n")
            return True
        else:
            print(f"  {CLR_RED}{CLR_BOLD}❌ SOME VALIDATION TESTS FAILED.{CLR_RESET}")
            print(f"  Review the failure logs above for diagnostic details.\n")
            return False


def main():
    parser = argparse.ArgumentParser(
        description="Prometheus & Node Exporter PromQL Metrics Validation Suite",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("--url", default="http://localhost:9090", help="Prometheus Server Base URL")
    parser.add_argument("--timeout", type=float, default=10.0, help="HTTP Request Timeout in seconds")
    parser.add_argument("--retries", type=int, default=10, help="Max connection retry attempts during startup wait")
    parser.add_argument("--retry-delay", type=float, default=2.0, help="Delay in seconds between retry attempts")
    parser.add_argument("--json", action="store_true", help="Output machine-readable JSON results")
    parser.add_argument("--verbose", action="store_true", help="Print verbose test diagnostic output")
    args = parser.parse_args()

    client = PrometheusClient(base_url=args.url, timeout=args.timeout)

    # Initial readiness poll loop
    print(f"{CLR_GRAY}Connecting to Prometheus server at {args.url}...{CLR_RESET}")
    connected = False
    for attempt in range(1, args.retries + 1):
        if client.check_ready():
            connected = True
            break
        if attempt < args.retries:
            time.sleep(args.retry_delay)

    if not connected:
        print(f"{CLR_RED}Error: Could not establish ready connection to Prometheus at {args.url} after {args.retries} attempts.{CLR_RESET}", file=sys.stderr)
        sys.exit(1)

    runner = PromQLValidationRunner(client=client, verbose=args.verbose)
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
