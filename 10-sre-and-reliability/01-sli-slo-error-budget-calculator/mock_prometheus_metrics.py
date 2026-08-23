#!/usr/bin/env python3
"""
mock_prometheus_metrics.py - Synthetic Metrics & Traffic Generator for SRE Testing
===================================================================================
Simulates production microservice traffic and exports Prometheus-compatible metrics.
Provides real-time dynamic traffic generation, simulated historical data, and scenario
switching (healthy, degraded, outage, latency spike) for SLI/SLO testing.
"""

import argparse
import http.server
import json
import logging
import math
import os
import random
import socketserver
import sys
import threading
import time
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(threadName)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("mock_metrics")

# Default configuration
DEFAULT_PORT = int(os.environ.get("PORT", 8080))
SCRAPE_HISTOGRAM_BUCKETS = [0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.5, 5.0]

# Service profiles and endpoint definitions
SERVICES = {
    "checkout-service": {
        "endpoint": "/api/v1/checkout",
        "method": "POST",
        "rps": 50,
        "base_latency": 0.08,
    },
    "payment-gateway": {
        "endpoint": "/api/v1/payments/process",
        "method": "POST",
        "rps": 30,
        "base_latency": 0.12,
    },
    "catalog-service": {
        "endpoint": "/api/v1/products",
        "method": "GET",
        "rps": 120,
        "base_latency": 0.04,
    },
    "auth-service": {
        "endpoint": "/api/v1/auth/login",
        "method": "POST",
        "rps": 40,
        "base_latency": 0.05,
    },
}

# Predefined operational scenarios
SCENARIO_PRESETS = {
    "healthy": {
        "description": "Nominal operations: 99.96% success rate, low latency (p95 < 90ms)",
        "success_rate": 0.9996,
        "latency_multiplier": 1.0,
        "error_codes": ["500", "503"],
        "error_weights": [0.7, 0.3],
    },
    "minor_degradation": {
        "description": "Minor service degradation: 99.2% success rate, burns budget slowly (~8x burn rate on 99.9% SLO)",
        "success_rate": 0.9920,
        "latency_multiplier": 1.4,
        "error_codes": ["500", "502", "503", "504"],
        "error_weights": [0.4, 0.3, 0.2, 0.1],
    },
    "major_outage": {
        "description": "Catastrophic outage: 82.0% success rate, severe 5xx errors (180x burn rate)",
        "success_rate": 0.8200,
        "latency_multiplier": 2.5,
        "error_codes": ["500", "503"],
        "error_weights": [0.6, 0.4],
    },
    "latency_spike": {
        "description": "High latency anomaly: 99.9% 2xx responses but 45% requests exceed 200ms threshold",
        "success_rate": 0.9990,
        "latency_multiplier": 4.5,
        "error_codes": ["500", "504"],
        "error_weights": [0.3, 0.7],
    },
    "service_down": {
        "description": "Total dependency failure: 0% success rate (all 503 Service Unavailable)",
        "success_rate": 0.0000,
        "latency_multiplier": 1.0,
        "error_codes": ["503"],
        "error_weights": [1.0],
    },
}


class MetricsStore:
    """Thread-safe in-memory store for Prometheus time-series counters and histograms."""

    def __init__(self):
        self._lock = threading.Lock()
        self.active_scenario = "healthy"
        self.start_time = time.time()
        self.scenario_start_time = time.time()
        self.reset()

    def reset(self, initial_baseline: bool = True):
        with self._lock:
            self.requests_total: Dict[Tuple[str, str, str, str], float] = {}
            self.duration_buckets: Dict[Tuple[str, str, float], float] = {}
            self.duration_sum: Dict[Tuple[str, str], float] = {}
            self.duration_count: Dict[Tuple[str, str], float] = {}
            self.scenario_start_time = time.time()

            # Initialize zero counters for all combinations
            for svc, cfg in SERVICES.items():
                ep = cfg["endpoint"]
                method = cfg["method"]
                for status in ["200", "201", "400", "401", "404", "500", "502", "503", "504"]:
                    self.requests_total[(svc, ep, method, status)] = 0.0

                for le in SCRAPE_HISTOGRAM_BUCKETS:
                    self.duration_buckets[(svc, ep, le)] = 0.0
                self.duration_buckets[(svc, ep, float("inf"))] = 0.0
                self.duration_sum[(svc, ep)] = 0.0
                self.duration_count[(svc, ep)] = 0.0

            # Seed with baseline initial counts so rate() calculations work immediately
            if initial_baseline:
                self._seed_baseline(hours=1.0)

    def _seed_baseline(self, hours: float = 1.0):
        """Seed initial non-zero sample counts representing previous healthy activity."""
        seconds = hours * 3600.0
        for svc, cfg in SERVICES.items():
            ep = cfg["endpoint"]
            method = cfg["method"]
            total_reqs = cfg["rps"] * seconds

            # Baseline 99.96% success
            good_reqs = total_reqs * 0.9996
            bad_reqs = total_reqs - good_reqs

            self.requests_total[(svc, ep, method, "200")] = good_reqs * 0.95
            self.requests_total[(svc, ep, method, "201")] = good_reqs * 0.05
            self.requests_total[(svc, ep, method, "500")] = bad_reqs * 0.7
            self.requests_total[(svc, ep, method, "503")] = bad_reqs * 0.3

            base_lat = cfg["base_latency"]
            self.duration_count[(svc, ep)] = total_reqs
            self.duration_sum[(svc, ep)] = total_reqs * base_lat

            # Distribute into histogram buckets
            for le in SCRAPE_HISTOGRAM_BUCKETS:
                # Cumulative percentage of requests under le
                if le < base_lat * 0.5:
                    pct = 0.05
                elif le < base_lat:
                    pct = 0.50
                elif le < base_lat * 1.5:
                    pct = 0.85
                elif le < base_lat * 2.5:
                    pct = 0.97
                else:
                    pct = 1.00
                self.duration_buckets[(svc, ep, le)] = total_reqs * pct

            self.duration_buckets[(svc, ep, float("inf"))] = total_reqs

    def set_scenario(self, scenario_name: str) -> bool:
        if scenario_name not in SCENARIO_PRESETS:
            return False
        with self._lock:
            self.active_scenario = scenario_name
            self.scenario_start_time = time.time()
        logger.info("Switched operational scenario to: '%s' (%s)", scenario_name, SCENARIO_PRESETS[scenario_name]["description"])
        return True

    def record_tick(self, interval_seconds: float = 1.0):
        """Simulate traffic tick for the active scenario."""
        with self._lock:
            preset = SCENARIO_PRESETS[self.active_scenario]
            success_rate = preset["success_rate"]
            lat_multiplier = preset["latency_multiplier"]

            for svc, cfg in SERVICES.items():
                ep = cfg["endpoint"]
                method = cfg["method"]
                tick_requests = max(1, int(cfg["rps"] * interval_seconds))

                # Determine good vs error request split
                if success_rate >= 1.0:
                    num_good = tick_requests
                    num_bad = 0
                elif success_rate <= 0.0:
                    num_good = 0
                    num_bad = tick_requests
                else:
                    num_bad = sum(1 for _ in range(tick_requests) if random.random() > success_rate)
                    num_good = tick_requests - num_bad

                # Record 2xx responses
                if num_good > 0:
                    self.requests_total[(svc, ep, method, "200")] += num_good

                # Record 5xx responses
                if num_bad > 0:
                    err_code = random.choices(preset["error_codes"], weights=preset["error_weights"], k=1)[0]
                    self.requests_total[(svc, ep, method, err_code)] = (
                        self.requests_total.get((svc, ep, method, err_code), 0.0) + num_bad
                    )

                # Generate latency observations
                base_lat = cfg["base_latency"] * lat_multiplier
                for _ in range(tick_requests):
                    # Log-normal distribution for realistic latency tail
                    obs_lat = max(0.005, random.lognormvariate(math.log(base_lat), 0.35))
                    self.duration_count[(svc, ep)] += 1
                    self.duration_sum[(svc, ep)] += obs_lat

                    for le in SCRAPE_HISTOGRAM_BUCKETS:
                        if obs_lat <= le:
                            self.duration_buckets[(svc, ep, le)] += 1
                    self.duration_buckets[(svc, ep, float("inf"))] += 1

    def generate_prometheus_metrics(self) -> str:
        """Render metrics in Prometheus text-based exposition format."""
        lines: List[str] = [
            "# HELP http_requests_total Total number of HTTP requests processed by service, endpoint, method and status.",
            "# TYPE http_requests_total counter",
        ]

        with self._lock:
            for (svc, ep, method, status), val in sorted(self.requests_total.items()):
                if val > 0:
                    lines.append(
                        f'http_requests_total{{service="{svc}",endpoint="{ep}",method="{method}",status="{status}"}} {val:.1f}'
                    )

            lines.append("")
            lines.append("# HELP http_request_duration_seconds HTTP request latency distribution in seconds.")
            lines.append("# TYPE http_request_duration_seconds histogram")

            for svc, cfg in sorted(SERVICES.items()):
                ep = cfg["endpoint"]
                for le in SCRAPE_HISTOGRAM_BUCKETS:
                    b_val = self.duration_buckets.get((svc, ep, le), 0.0)
                    lines.append(f'http_request_duration_seconds_bucket{{service="{svc}",endpoint="{ep}",le="{le}"}} {b_val:.1f}')

                inf_val = self.duration_buckets.get((svc, ep, float("inf")), 0.0)
                lines.append(f'http_request_duration_seconds_bucket{{service="{svc}",endpoint="{ep}",le="+Inf"}} {inf_val:.1f}')

                sum_val = self.duration_sum.get((svc, ep), 0.0)
                lines.append(f'http_request_duration_seconds_sum{{service="{svc}",endpoint="{ep}"}} {sum_val:.4f}')

                cnt_val = self.duration_count.get((svc, ep), 0.0)
                lines.append(f'http_request_duration_seconds_count{{service="{svc}",endpoint="{ep}"}} {cnt_val:.1f}')

            lines.append("")
            lines.append("# HELP app_up Microservice operational health indicator (1 = Healthy, 0 = Down).")
            lines.append("# TYPE app_up gauge")
            for svc in sorted(SERVICES.keys()):
                is_up = 0 if self.active_scenario == "service_down" else 1
                lines.append(f'app_up{{service="{svc}"}} {is_up}')

            lines.append("")
            lines.append("# HELP mock_service_scenario Current active operational scenario identifier.")
            lines.append("# TYPE mock_service_scenario gauge")
            lines.append(f'mock_service_scenario{{scenario="{self.active_scenario}"}} 1')

        lines.append("")
        return "\n".join(lines)

    def get_summary(self) -> Dict[str, Any]:
        with self._lock:
            total_reqs = sum(self.requests_total.values())
            error_reqs = sum(
                val for (svc, ep, method, status), val in self.requests_total.items() if status.startswith("5")
            )
            good_reqs = total_reqs - error_reqs
            overall_sli = (good_reqs / total_reqs * 100.0) if total_reqs > 0 else 100.0

            return {
                "active_scenario": self.active_scenario,
                "scenario_info": SCENARIO_PRESETS[self.active_scenario],
                "uptime_seconds": round(time.time() - self.start_time, 1),
                "scenario_duration_seconds": round(time.time() - self.scenario_start_time, 1),
                "metrics_summary": {
                    "total_requests": round(total_reqs, 0),
                    "good_requests": round(good_reqs, 0),
                    "error_requests": round(error_reqs, 0),
                    "overall_sli_percent": round(overall_sli, 4),
                },
                "services": list(SERVICES.keys()),
            }


# Global store instance
store = MetricsStore()


class MockRequestHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler serving /metrics, /scenario/<name>, /api/scenario, and /health."""

    def log_message(self, format_str: str, *args: Any):
        # Suppress routine scrape log spam
        if "GET /metrics" not in format_str % args and "GET /health" not in format_str % args:
            logger.info("%s - %s", self.client_address[0], format_str % args)

    def do_GET(self):
        if self.path == "/metrics":
            content = store.generate_prometheus_metrics().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        elif self.path in ("/health", "/healthz"):
            resp = json.dumps({"status": "healthy", "service": "mock-prometheus-metrics"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        elif self.path in ("/scenario", "/scenario/status", "/api/scenario"):
            summary = store.get_summary()
            resp = json.dumps(summary, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        elif self.path.startswith("/scenario/"):
            scenario_name = self.path.replace("/scenario/", "").strip().lower()
            if scenario_name == "reset":
                store.reset(initial_baseline=True)
                resp = json.dumps({"message": "Metrics reset to initial baseline", "status": "ok"}).encode("utf-8")
                self.send_response(200)
            elif store.set_scenario(scenario_name):
                resp = json.dumps(
                    {
                        "message": f"Switched to scenario '{scenario_name}'",
                        "scenario": SCENARIO_PRESETS[scenario_name],
                        "status": "ok",
                    }
                ).encode("utf-8")
                self.send_response(200)
            else:
                resp = json.dumps(
                    {
                        "error": f"Invalid scenario '{scenario_name}'",
                        "available_scenarios": list(SCENARIO_PRESETS.keys()) + ["reset"],
                    }
                ).encode("utf-8")
                self.send_response(400)

            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        elif self.path.startswith("/api/v1/query"):
            # Mock Prometheus query endpoint for standalone/offline testing
            self._handle_mock_prometheus_query()

        else:
            resp = json.dumps(
                {
                    "error": "Not Found",
                    "routes": [
                        "GET /metrics - Prometheus metrics exposition endpoint",
                        "GET /health - Health check endpoint",
                        "GET /scenario/status - Current scenario and traffic state",
                        "GET /scenario/<healthy|minor_degradation|major_outage|latency_spike|service_down|reset>",
                        "POST /scenario/<name> - Switch scenario via POST",
                    ],
                }
            ).encode("utf-8")
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

    def do_POST(self):
        if self.path.startswith("/scenario/"):
            scenario_name = self.path.replace("/scenario/", "").strip().lower()
            if scenario_name == "reset":
                store.reset(initial_baseline=True)
                resp = json.dumps({"message": "Metrics reset to initial baseline", "status": "ok"}).encode("utf-8")
                self.send_response(200)
            elif store.set_scenario(scenario_name):
                resp = json.dumps(
                    {
                        "message": f"Switched to scenario '{scenario_name}'",
                        "scenario": SCENARIO_PRESETS[scenario_name],
                        "status": "ok",
                    }
                ).encode("utf-8")
                self.send_response(200)
            else:
                resp = json.dumps(
                    {
                        "error": f"Invalid scenario '{scenario_name}'",
                        "available_scenarios": list(SCENARIO_PRESETS.keys()) + ["reset"],
                    }
                ).encode("utf-8")
                self.send_response(400)

            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
        else:
            self.send_response(404)
            self.end_headers()

    def _handle_mock_prometheus_query(self):
        """Simulate Prometheus HTTP query API responses based on active scenario."""
        import urllib.parse

        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        query = params.get("query", [""])[0]

        now_ts = time.time()
        result_value = 0.0

        # Heuristic query matching for mock evaluation
        if "http_requests_total" in query:
            if 'status!~"5.."' in query:
                # Good requests
                preset = SCENARIO_PRESETS[store.active_scenario]
                if "checkout-service" in query:
                    result_value = SERVICES["checkout-service"]["rps"] * preset["success_rate"]
                elif "payment-gateway" in query:
                    result_value = SERVICES["payment-gateway"]["rps"] * preset["success_rate"]
                elif "auth-service" in query:
                    result_value = SERVICES["auth-service"]["rps"] * preset["success_rate"]
                else:
                    total_rps = sum(s["rps"] for s in SERVICES.values())
                    result_value = total_rps * preset["success_rate"]
            else:
                # Total requests
                if "checkout-service" in query:
                    result_value = SERVICES["checkout-service"]["rps"]
                elif "payment-gateway" in query:
                    result_value = SERVICES["payment-gateway"]["rps"]
                elif "auth-service" in query:
                    result_value = SERVICES["auth-service"]["rps"]
                else:
                    result_value = sum(s["rps"] for s in SERVICES.values())

        elif "http_request_duration_seconds_bucket" in query:
            preset = SCENARIO_PRESETS[store.active_scenario]
            rps = SERVICES["catalog-service"]["rps"]
            if preset == "latency_spike":
                result_value = rps * 0.55  # 55% within 200ms
            else:
                result_value = rps * 0.98  # 98% within 200ms

        elif "http_request_duration_seconds_count" in query:
            result_value = SERVICES["catalog-service"]["rps"]

        resp_data = {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [
                    {
                        "metric": {},
                        "value": [now_ts, str(result_value)],
                    }
                ],
            },
        }
        body = json.dumps(resp_data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def background_traffic_worker(stop_event: threading.Event, interval: float = 1.0):
    """Background loop generating continuous traffic samples."""
    logger.info("Starting background synthetic traffic generator (interval: %.1fs)...", interval)
    while not stop_event.is_set():
        try:
            store.record_tick(interval)
        except Exception as err:
            logger.error("Error in traffic generator: %s", err)
        time.sleep(interval)


def run_server(port: int = DEFAULT_PORT):
    stop_event = threading.Event()
    worker_thread = threading.Thread(
        target=background_traffic_worker,
        args=(stop_event, 1.0),
        name="TrafficWorker",
        daemon=True,
    )
    worker_thread.start()

    class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedHTTPServer(("0.0.0.0", port), MockRequestHandler)
    logger.info("Mock Prometheus Metrics Server listening on http://0.0.0.0:%d", port)
    logger.info("Metrics endpoint: http://0.0.0.0:%d/metrics", port)
    logger.info("Scenarios available: %s", list(SCENARIO_PRESETS.keys()))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down server...")
        stop_event.set()
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description="Synthetic Prometheus Metrics & Traffic Generator")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT, help="Port to listen on (default: 8080)")
    parser.add_argument("--scenario", "-s", choices=list(SCENARIO_PRESETS.keys()), default="healthy", help="Initial scenario")
    args = parser.parse_args()

    store.set_scenario(args.scenario)
    run_server(args.port)


if __name__ == "__main__":
    main()
