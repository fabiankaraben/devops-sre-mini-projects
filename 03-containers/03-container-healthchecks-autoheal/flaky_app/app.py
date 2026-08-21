#!/usr/bin/env python3
"""
Flaky Microservice with Controlled Failure Injection
====================================================
Simulates application deadlocks, memory leaks, and backend dependency
failures to test Docker HEALTHCHECK probing and automated container recovery.
"""

import json
import logging
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("flaky-app")

PORT = int(os.getenv("PORT", "8080"))
START_TIME = time.time()

# Internal state
STATE = {
    "status": "HEALTHY",
    "failure_reason": None,
    "broken_at": None,
    "request_count": 0,
    "healthcheck_count": 0,
}


class FlakyHandler(BaseHTTPRequestHandler):
    """HTTP Request Handler supporting chaos injection."""

    def _set_headers(self, status_code=200, content_type="application/json"):
        self.send_response(status_code)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()

    def do_OPTIONS(self):
        self._set_headers(204)

    def _send_json(self, status_code, data):
        body = json.dumps(data, indent=2).encode("utf-8")
        self._set_headers(status_code)
        self.wfile.write(body)

    def do_GET(self):
        STATE["request_count"] += 1
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")

        if path == "" or path == "/":
            self._handle_root()
        elif path == "/health":
            self._handle_health()
        elif path == "/stats":
            self._handle_stats()
        else:
            self._send_json(404, {"error": "Route not found", "path": path})

    def do_POST(self):
        STATE["request_count"] += 1
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")

        if path == "/break":
            self._handle_break()
        elif path == "/heal":
            self._handle_heal()
        else:
            self._send_json(404, {"error": "Route not found", "path": path})

    def _handle_root(self):
        uptime = round(time.time() - START_TIME, 2)
        self._send_json(200, {
            "service": "flaky-healthcheck-demo",
            "version": "1.0.0",
            "state": STATE["status"],
            "is_healthy": STATE["status"] == "HEALTHY",
            "uptime_seconds": uptime,
            "pid": os.getpid(),
            "endpoints": {
                "health_probe": "GET /health (HTTP 200 when healthy, HTTP 503 when broken)",
                "inject_chaos": "POST /break (Corrupts health probe to simulate failure)",
                "manual_heal": "POST /heal (Restores health to UP)",
                "statistics": "GET /stats (View request counters and uptime)",
            },
        })

    def _handle_health(self):
        STATE["healthcheck_count"] += 1
        uptime = round(time.time() - START_TIME, 2)

        if STATE["status"] == "HEALTHY":
            self._send_json(200, {
                "status": "UP",
                "state": "HEALTHY",
                "uptime_seconds": uptime,
                "healthcheck_probes": STATE["healthcheck_count"],
            })
        else:
            broken_duration = round(time.time() - (STATE["broken_at"] or time.time()), 2)
            logger.warning("Health probe failed (503). Reason: %s (Broken for %ss)", STATE["failure_reason"], broken_duration)
            self._send_json(503, {
                "status": "DOWN",
                "state": "UNHEALTHY",
                "error": "Service degraded / failure simulated",
                "reason": STATE["failure_reason"],
                "broken_duration_seconds": broken_duration,
                "uptime_seconds": uptime,
            })

    def _handle_break(self):
        STATE["status"] = "UNHEALTHY"
        STATE["failure_reason"] = "Simulated deadlock / database pool exhaustion"
        STATE["broken_at"] = time.time()
        logger.error("💥 CHAOS INJECTED: Service is now BROKEN. /health will return HTTP 503.")

        self._send_json(200, {
            "message": "Chaos injected successfully. Application is now corrupted.",
            "state": "UNHEALTHY",
            "action": "Docker daemon will mark this container as UNHEALTHY on next probe cycle.",
        })

    def _handle_heal(self):
        STATE["status"] = "HEALTHY"
        STATE["failure_reason"] = None
        STATE["broken_at"] = None
        logger.info("✨ Service manually healed. /health returning HTTP 200.")

        self._send_json(200, {
            "message": "Service manually healed.",
            "state": "HEALTHY",
        })

    def _handle_stats(self):
        self._send_json(200, {
            "state": STATE["status"],
            "total_requests": STATE["request_count"],
            "total_healthchecks": STATE["healthcheck_count"],
            "uptime_seconds": round(time.time() - START_TIME, 2),
            "pid": os.getpid(),
        })

    def log_message(self, format, *args):
        # Silence standard log spam for /health probes
        if "/health" not in (args[0] if args else ""):
            logger.info("%s - - [%s] %s", self.address_string(), self.log_date_time_string(), format % args)


def run():
    server_address = ("", PORT)
    httpd = HTTPServer(server_address, FlakyHandler)

    def signal_handler(signum, frame):
        logger.info("Received signal %s. Shutting down gracefully...", signum)
        httpd.server_close()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    logger.info("🚀 Flaky App running on port %d (PID: %d)", PORT, os.getpid())
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        logger.info("Flaky App stopped.")


if __name__ == "__main__":
    run()
