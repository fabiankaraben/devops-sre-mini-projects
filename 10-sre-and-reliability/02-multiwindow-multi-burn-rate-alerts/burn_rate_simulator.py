#!/usr/bin/env python3
"""
burn_rate_simulator.py - Synthetic Traffic & Error Burn Rate Spike Generator
============================================================================
Simulates production microservices and generates Prometheus metrics with dynamic
error rate injection to trigger and test Google SRE Multiwindow Multi-Burn-Rate
alerting rules.
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
import urllib.parse
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(threadName)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("burn_rate_simulator")

DEFAULT_PORT = int(os.environ.get("PORT", 8080))
HISTOGRAM_BUCKETS = [0.05, 0.1, 0.2, 0.5, 1.0, 2.5, 5.0]

# Monitored services configuration
SERVICES = {
    "checkout-service": {
        "endpoint": "/api/v1/checkout",
        "method": "POST",
        "rps": 60,
        "slo_target": 0.999,  # 99.9% availability
        "base_latency": 0.075,
    },
    "payment-service": {
        "endpoint": "/api/v1/payments",
        "method": "POST",
        "rps": 40,
        "slo_target": 0.9995,  # 99.95% availability
        "base_latency": 0.110,
    },
    "order-processing": {
        "endpoint": "/api/v1/orders",
        "method": "POST",
        "rps": 50,
        "slo_target": 0.995,  # 99.5% availability
        "base_latency": 0.060,
    },
}

# Predefined burn rate injection profiles
PRESETS = {
    "healthy": {
        "description": "Nominal operations: 0.02% error rate (99.98% success, burn rate ~0.2x)",
        "error_rate": 0.0002,
        "latency_mult": 1.0,
    },
    "slow-burn": {
        "description": "Slow silent budget drain: 0.3% error rate (burn rate ~3.0x on 99.9% SLO, triggers 24h ticket alert)",
        "error_rate": 0.0030,
        "latency_mult": 1.3,
    },
    "medium-burn": {
        "description": "Elevated outage: 1.5% error rate (burn rate ~15.0x, triggers 6h page alert)",
        "error_rate": 0.0150,
        "latency_mult": 1.8,
    },
    "fast-burn": {
        "description": "Catastrophic outage: 15.0% error rate (burn rate ~150.0x, triggers 14.4x 1h/5m page alert within 2 minutes)",
        "error_rate": 0.1500,
        "latency_mult": 2.5,
    },
    "critical-blackout": {
        "description": "Total service blackout: 100% error rate (burn rate ~1000x, immediate critical page)",
        "error_rate": 1.0000,
        "latency_mult": 4.0,
    },
}


class BurnRateStore:
    """Thread-safe state manager for Prometheus counters, histograms, and active scenario."""

    def __init__(self):
        self._lock = threading.Lock()
        self.active_preset = "healthy"
        self.custom_error_rate: Optional[float] = None
        self.start_time = time.time()
        self.scenario_start_time = time.time()

        self.requests_total: Dict[Tuple[str, str, str, str], float] = {}
        self.duration_buckets: Dict[Tuple[str, str, float], float] = {}
        self.duration_sum: Dict[Tuple[str, str], float] = {}
        self.duration_count: Dict[Tuple[str, str], float] = {}
        self.received_alerts: List[Dict[str, Any]] = []

        self.reset(seed_history=True)

    def reset(self, seed_history: bool = True):
        with self._lock:
            self.requests_total.clear()
            self.duration_buckets.clear()
            self.duration_sum.clear()
            self.duration_count.clear()
            self.scenario_start_time = time.time()

            # Initialize zero metrics
            for svc, cfg in SERVICES.items():
                ep = cfg["endpoint"]
                method = cfg["method"]
                for status in ["200", "201", "400", "404", "500", "502", "503"]:
                    self.requests_total[(svc, ep, method, status)] = 0.0

                for le in HISTOGRAM_BUCKETS:
                    self.duration_buckets[(svc, ep, le)] = 0.0
                self.duration_buckets[(svc, ep, float("inf"))] = 0.0
                self.duration_sum[(svc, ep)] = 0.0
                self.duration_count[(svc, ep)] = 0.0

            if seed_history:
                self._seed_baseline(hours=2.0)

    def _seed_baseline(self, hours: float = 2.0):
        """Seed initial non-zero request counters representing past nominal healthy traffic."""
        seconds = hours * 3600.0
        for svc, cfg in SERVICES.items():
            ep = cfg["endpoint"]
            method = cfg["method"]
            total_reqs = cfg["rps"] * seconds
            err_rate = 0.0002  # 0.02% baseline errors
            bad_reqs = total_reqs * err_rate
            good_reqs = total_reqs - bad_reqs

            self.requests_total[(svc, ep, method, "200")] = good_reqs
            self.requests_total[(svc, ep, method, "500")] = bad_reqs * 0.7
            self.requests_total[(svc, ep, method, "503")] = bad_reqs * 0.3

            base_lat = cfg["base_latency"]
            self.duration_count[(svc, ep)] = total_reqs
            self.duration_sum[(svc, ep)] = total_reqs * base_lat
            for le in HISTOGRAM_BUCKETS:
                pct = 0.98 if le >= 0.2 else (0.80 if le >= 0.1 else 0.40)
                self.duration_buckets[(svc, ep, le)] = total_reqs * pct
            self.duration_buckets[(svc, ep, float("inf"))] = total_reqs

    def set_preset(self, preset_name: str) -> bool:
        if preset_name not in PRESETS:
            return False
        with self._lock:
            self.active_preset = preset_name
            self.custom_error_rate = None
            self.scenario_start_time = time.time()
        logger.info("Switched operational scenario to: '%s' (%s)", preset_name, PRESETS[preset_name]["description"])
        return True

    def set_custom_rate(self, error_rate: float):
        with self._lock:
            self.active_preset = "custom"
            self.custom_error_rate = max(0.0, min(1.0, error_rate))
            self.scenario_start_time = time.time()
        logger.info("Switched operational scenario to custom error rate: %.4f (%.2f%%)", self.custom_error_rate, self.custom_error_rate * 100.0)

    def get_current_error_rate(self) -> float:
        if self.custom_error_rate is not None:
            return self.custom_error_rate
        return PRESETS.get(self.active_preset, PRESETS["healthy"])["error_rate"]

    def record_tick(self, interval: float = 1.0):
        with self._lock:
            curr_error_rate = self.get_current_error_rate()
            preset_info = PRESETS.get(self.active_preset, PRESETS["healthy"])
            lat_mult = preset_info.get("latency_mult", 1.0)

            for svc, cfg in SERVICES.items():
                ep = cfg["endpoint"]
                method = cfg["method"]
                tick_requests = max(1, int(cfg["rps"] * interval))

                num_bad = sum(1 for _ in range(tick_requests) if random.random() < curr_error_rate)
                num_good = tick_requests - num_bad

                if num_good > 0:
                    self.requests_total[(svc, ep, method, "200")] += num_good

                if num_bad > 0:
                    status = "500" if random.random() < 0.7 else "503"
                    self.requests_total[(svc, ep, method, status)] = (
                        self.requests_total.get((svc, ep, method, status), 0.0) + num_bad
                    )

                base_lat = cfg["base_latency"] * lat_mult
                for _ in range(tick_requests):
                    obs_lat = max(0.005, random.lognormvariate(math.log(base_lat), 0.3))
                    self.duration_count[(svc, ep)] += 1
                    self.duration_sum[(svc, ep)] += obs_lat

                    for le in HISTOGRAM_BUCKETS:
                        if obs_lat <= le:
                            self.duration_buckets[(svc, ep, le)] += 1
                    self.duration_buckets[(svc, ep, float("inf"))] += 1

    def generate_prometheus_metrics(self) -> str:
        lines: List[str] = [
            "# HELP http_requests_total Total number of HTTP requests by service, endpoint, method, and status.",
            "# TYPE http_requests_total counter",
        ]

        with self._lock:
            for (svc, ep, method, status), val in sorted(self.requests_total.items()):
                if val > 0:
                    lines.append(
                        f'http_requests_total{{service="{svc}",endpoint="{ep}",method="{method}",status="{status}"}} {val:.1f}'
                    )

            lines.append("")
            lines.append("# HELP http_request_duration_seconds Request duration in seconds.")
            lines.append("# TYPE http_request_duration_seconds histogram")

            for svc, cfg in sorted(SERVICES.items()):
                ep = cfg["endpoint"]
                for le in HISTOGRAM_BUCKETS:
                    b_val = self.duration_buckets.get((svc, ep, le), 0.0)
                    lines.append(f'http_request_duration_seconds_bucket{{service="{svc}",endpoint="{ep}",le="{le}"}} {b_val:.1f}')

                inf_val = self.duration_buckets.get((svc, ep, float("inf")), 0.0)
                lines.append(f'http_request_duration_seconds_bucket{{service="{svc}",endpoint="{ep}",le="+Inf"}} {inf_val:.1f}')

                sum_val = self.duration_sum.get((svc, ep), 0.0)
                lines.append(f'http_request_duration_seconds_sum{{service="{svc}",endpoint="{ep}"}} {sum_val:.4f}')

                cnt_val = self.duration_count.get((svc, ep), 0.0)
                lines.append(f'http_request_duration_seconds_count{{service="{svc}",endpoint="{ep}"}} {cnt_val:.1f}')

            lines.append("")
            lines.append("# HELP burn_rate_simulator_error_rate_active Current target error rate injected (0.0 to 1.0).")
            lines.append("# TYPE burn_rate_simulator_error_rate_active gauge")
            curr_rate = self.get_current_error_rate()
            lines.append(f'burn_rate_simulator_error_rate_active{{scenario="{self.active_preset}"}} {curr_rate:.6f}')

            lines.append("")
            lines.append("# HELP burn_rate_simulator_burn_rate_multiplier Current theoretical burn rate multiplier.")
            lines.append("# TYPE burn_rate_simulator_burn_rate_multiplier gauge")
            for svc, cfg in sorted(SERVICES.items()):
                allowed_error = 1.0 - cfg["slo_target"]
                burn_mult = curr_rate / allowed_error if allowed_error > 0 else 0.0
                lines.append(f'burn_rate_simulator_burn_rate_multiplier{{service="{svc}"}} {burn_mult:.4f}')

        lines.append("")
        return "\n".join(lines)

    def get_status(self) -> Dict[str, Any]:
        with self._lock:
            curr_rate = self.get_current_error_rate()
            total_reqs = sum(self.requests_total.values())
            bad_reqs = sum(v for (s, e, m, st), v in self.requests_total.items() if st.startswith("5"))
            good_reqs = total_reqs - bad_reqs

            service_status = {}
            for svc, cfg in SERVICES.items():
                allowed_error = 1.0 - cfg["slo_target"]
                burn_rate = curr_rate / allowed_error if allowed_error > 0 else 0.0
                service_status[svc] = {
                    "slo_target_percent": cfg["slo_target"] * 100.0,
                    "allowed_error_rate": allowed_error,
                    "active_burn_rate_multiplier": round(burn_rate, 2),
                    "expected_alert_severity": (
                        "CRITICAL_PAGE_14_4X" if burn_rate >= 14.4
                        else "HIGH_PAGE_6_0X" if burn_rate >= 6.0
                        else "TICKET_WARNING_3_0X" if burn_rate >= 3.0
                        else "TICKET_NOTICE_1_0X" if burn_rate >= 1.0
                        else "NOMINAL_HEALTHY"
                    ),
                }

            return {
                "active_scenario": self.active_preset,
                "current_error_rate": curr_rate,
                "current_error_rate_percent": f"{curr_rate * 100.0:.3f}%",
                "uptime_seconds": round(time.time() - self.start_time, 1),
                "scenario_duration_seconds": round(time.time() - self.scenario_start_time, 1),
                "cumulative_totals": {
                    "total_requests": round(total_reqs, 0),
                    "good_requests": round(good_reqs, 0),
                    "error_requests": round(bad_reqs, 0),
                    "overall_success_sli_percent": round(good_reqs / total_reqs * 100.0, 4) if total_reqs > 0 else 100.0,
                },
                "services": service_status,
                "available_presets": list(PRESETS.keys()),
            }


store = BurnRateStore()


class SimulatorRequestHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler serving /metrics, /inject/<preset>, /status, and /health."""

    def log_message(self, format_str: str, *args: Any):
        if "GET /metrics" not in format_str % args and "GET /health" not in format_str % args:
            logger.info("%s - %s", self.client_address[0], format_str % args)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        query_params = urllib.parse.parse_qs(parsed.query)

        if path == "/metrics":
            content = store.generate_prometheus_metrics().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        elif path in ("/health", "/healthz"):
            resp = json.dumps({"status": "healthy", "service": "burn-rate-simulator"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        elif path in ("/status", "/api/status"):
            status_data = store.get_status()
            resp = json.dumps(status_data, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        elif path in ("/alerts/received", "/api/alerts"):
            with store._lock:
                received = list(store.received_alerts)
            resp = json.dumps({"received_alerts_count": len(received), "alerts": received}, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        elif path.startswith("/inject/"):
            scenario = path.replace("/inject/", "").strip().lower()
            self._handle_inject(scenario, query_params)

        else:
            resp = json.dumps(
                {
                    "error": "Not Found",
                    "available_endpoints": [
                        "GET  /metrics - Prometheus scrape endpoint",
                        "GET  /health - Health check endpoint",
                        "GET  /status - Current error rate & burn rate state",
                        "POST /inject/fast-burn - Inject 15% error rate (150x burn rate)",
                        "POST /inject/medium-burn - Inject 1.5% error rate (15x burn rate)",
                        "POST /inject/slow-burn - Inject 0.3% error rate (3x burn rate)",
                        "POST /inject/healthy - Restore nominal healthy traffic (0.02% error rate)",
                        "POST /inject/custom?error_rate=0.08 - Inject custom error rate",
                    ],
                }
            ).encode("utf-8")
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        query_params = urllib.parse.parse_qs(parsed.query)

        if path in ("/alerts/webhook", "/api/alerts/webhook"):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
            try:
                alert_payload = json.loads(body)
                with store._lock:
                    store.received_alerts.append({
                        "received_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "payload": alert_payload,
                    })
                logger.info("Received Alertmanager Webhook notification: %d alerts", len(alert_payload.get("alerts", [])))
            except Exception as err:
                logger.error("Failed to parse incoming webhook alert: %s", err)

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        elif path.startswith("/inject/"):
            scenario = path.replace("/inject/", "").strip().lower()
            self._handle_inject(scenario, query_params)
        else:
            self.send_response(404)
            self.end_headers()

    def _handle_inject(self, scenario: str, params: Dict[str, List[str]]):
        if scenario == "custom":
            rate_val = float(params.get("error_rate", ["0.05"])[0])
            store.set_custom_rate(rate_val)
            resp = json.dumps(
                {
                    "message": f"Injected custom error rate: {rate_val:.4f}",
                    "status": store.get_status(),
                }
            ).encode("utf-8")
            self.send_response(200)
        elif scenario == "reset":
            store.reset(seed_history=True)
            resp = json.dumps({"message": "Metrics reset to initial baseline", "status": store.get_status()}).encode("utf-8")
            self.send_response(200)
        elif store.set_preset(scenario):
            resp = json.dumps(
                {
                    "message": f"Switched operational scenario to '{scenario}'",
                    "status": store.get_status(),
                }
            ).encode("utf-8")
            self.send_response(200)
        else:
            resp = json.dumps(
                {
                    "error": f"Invalid scenario '{scenario}'",
                    "available_scenarios": list(PRESETS.keys()) + ["custom", "reset"],
                }
            ).encode("utf-8")
            self.send_response(400)

        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


def traffic_generator_worker(stop_event: threading.Event, interval: float = 1.0):
    logger.info("Starting background traffic simulator worker (interval: %.1fs)...", interval)
    while not stop_event.is_set():
        try:
            store.record_tick(interval)
        except Exception as err:
            logger.error("Error in simulator loop: %s", err)
        time.sleep(interval)


def run_server(port: int = DEFAULT_PORT):
    stop_event = threading.Event()
    worker = threading.Thread(
        target=traffic_generator_worker,
        args=(stop_event, 1.0),
        name="TrafficGenWorker",
        daemon=True,
    )
    worker.start()

    class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedHTTPServer(("0.0.0.0", port), SimulatorRequestHandler)
    logger.info("Burn Rate Simulator listening on http://0.0.0.0:%d", port)
    logger.info("Prometheus metrics endpoint: http://0.0.0.0:%d/metrics", port)
    logger.info("Scenarios available: %s", list(PRESETS.keys()))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down simulator server...")
        stop_event.set()
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description="Google SRE Burn Rate Traffic Simulator")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT, help="Port to listen on (default: 8080)")
    parser.add_argument("--scenario", "-s", choices=list(PRESETS.keys()), default="healthy", help="Initial scenario")
    args = parser.parse_args()

    store.set_preset(args.scenario)
    run_server(args.port)


if __name__ == "__main__":
    main()
