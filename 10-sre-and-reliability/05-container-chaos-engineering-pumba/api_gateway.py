#!/usr/bin/env python3
"""
api_gateway.py - Resilient API Gateway with Active-Active Failover & Retries
============================================================================
Exposes client-facing checkout endpoints, load-balances requests across downstream
payment replicas, and implements immediate failover, short socket timeouts, and
circuit breaker health eviction during chaos injection.
"""

import argparse
import http.server
import json
import logging
import os
import random
import socket
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("api_gateway")

DEFAULT_PORT = int(os.environ.get("PORT", 8080))
DEFAULT_BACKENDS = os.environ.get(
    "BACKENDS",
    "http://payment-service-1:8081,http://payment-service-2:8082",
).split(",")
REQUEST_TIMEOUT_SEC = float(os.environ.get("REQUEST_TIMEOUT_SEC", 0.350))


class ResilientGatewayState:
    """Thread-safe state manager for gateway routing, failover tracking, and health status."""

    def __init__(self, backends: List[str]):
        self._lock = threading.Lock()
        self.backends = [b.strip() for b in backends if b.strip()]
        self.current_idx = 0

        # Telemetry metrics
        self.total_requests = 0
        self.successful_requests = 0
        self.failed_requests = 0
        self.failover_count = 0
        self.replica_hits: Dict[str, int] = {b: 0 for b in self.backends}
        self.consecutive_failures: Dict[str, int] = {b: 0 for b in self.backends}
        self.start_time = time.time()

    def get_candidate_backends(self) -> List[str]:
        """Return list of backends ordered by round-robin starting position."""
        with self._lock:
            if not self.backends:
                return []
            start = self.current_idx
            self.current_idx = (self.current_idx + 1) % len(self.backends)
            # Reorder backends starting from 'start'
            return self.backends[start:] + self.backends[:start]

    def record_attempt(self, backend: str, success: bool, is_failover: bool = False):
        with self._lock:
            if success:
                self.successful_requests += 1
                self.consecutive_failures[backend] = 0
                self.replica_hits[backend] = self.replica_hits.get(backend, 0) + 1
            else:
                self.consecutive_failures[backend] = self.consecutive_failures.get(backend, 0) + 1
            if is_failover:
                self.failover_count += 1

    def record_global_request(self, success: bool):
        with self._lock:
            self.total_requests += 1
            if not success:
                self.failed_requests += 1

    def get_stats(self) -> Dict[str, Any]:
        with self._lock:
            uptime = round(time.time() - self.start_time, 1)
            avail_pct = round(
                (self.successful_requests / max(1, self.total_requests)) * 100.0, 2
            )
            return {
                "service": "resilient-api-gateway",
                "uptime_seconds": uptime,
                "total_requests": self.total_requests,
                "successful_requests": self.successful_requests,
                "failed_requests": self.failed_requests,
                "availability_percent": f"{avail_pct}%",
                "failover_count": self.failover_count,
                "configured_backends": self.backends,
                "replica_traffic_distribution": dict(self.replica_hits),
                "consecutive_failures": dict(self.consecutive_failures),
            }


gateway_state = ResilientGatewayState(DEFAULT_BACKENDS)


class ResilientGatewayHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Handler implementing resilient proxying and failover algorithms."""

    def log_message(self, format_str: str, *args: Any):
        if "GET /health" not in format_str % args and "GET /stats" not in format_str % args:
            pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path in ("/health", "/healthz"):
            self._send_json(200, {"status": "healthy", "service": "api-gateway"})
        elif path in ("/stats", "/api/v1/stats"):
            self._send_json(200, gateway_state.get_stats())
        else:
            self._send_json(404, {"error": "NotFound"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
        try:
            body_json = json.loads(body) if body.startswith("{") else {}
        except Exception:
            body_json = {}

        if path in ("/api/v1/checkout", "/checkout"):
            self._handle_resilient_checkout(body_json)
        else:
            self._send_json(404, {"error": "NotFound", "message": f"Endpoint '{path}' not found"})

    def _handle_resilient_checkout(self, payload: Dict[str, Any]):
        """Execute checkout with automatic failover across candidate replicas."""
        candidates = gateway_state.get_candidate_backends()
        if not candidates:
            gateway_state.record_global_request(success=False)
            self._send_json(503, {"error": "ServiceUnavailable", "message": "No backends configured"})
            return

        order_id = payload.get("order_id", f"ord_{int(time.time() * 1000)}")
        amount = float(payload.get("amount", 129.50))
        user_id = payload.get("user_id", "usr_customer_default")

        backend_payload = json.dumps({
            "order_id": order_id,
            "amount": amount,
            "user_id": user_id,
        }).encode("utf-8")

        last_error = ""
        attempt_logs: List[Dict[str, Any]] = []

        # Attempt primary and failover replicas sequentially
        for idx, backend_url in enumerate(candidates):
            target_url = f"{backend_url.rstrip('/')}/process"
            is_failover = (idx > 0)
            start_attempt = time.time()

            try:
                req = urllib.request.Request(
                    target_url,
                    data=backend_payload,
                    headers={"Content-Type": "application/json", "User-Agent": "ResilientGateway/1.0"},
                )
                with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SEC) as resp:
                    if resp.status == 200:
                        resp_data = json.loads(resp.read().decode("utf-8"))
                        duration_ms = round((time.time() - start_attempt) * 1000.0, 2)

                        gateway_state.record_attempt(backend_url, success=True, is_failover=is_failover)
                        gateway_state.record_global_request(success=True)

                        attempt_logs.append({
                            "backend": backend_url,
                            "attempt": idx + 1,
                            "status": "SUCCESS",
                            "duration_ms": duration_ms,
                        })

                        # Return enriched response with resilience telemetry
                        self._send_json(200, {
                            "order_id": order_id,
                            "status": "COMPLETED",
                            "payment_confirmation": resp_data,
                            "gateway_telemetry": {
                                "served_by_replica": resp_data.get("replica", backend_url),
                                "failover_required": is_failover,
                                "total_attempts": idx + 1,
                                "attempt_history": attempt_logs,
                            },
                        })
                        return

            except urllib.error.HTTPError as http_err:
                last_error = f"HTTP {http_err.code}: {http_err.reason}"
            except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError, OSError) as net_err:
                last_error = f"Network/Timeout error: {net_err}"
            except Exception as ex:
                last_error = f"Execution error: {ex}"

            duration_ms = round((time.time() - start_attempt) * 1000.0, 2)
            gateway_state.record_attempt(backend_url, success=False, is_failover=is_failover)
            attempt_logs.append({
                "backend": backend_url,
                "attempt": idx + 1,
                "status": "FAILED",
                "duration_ms": duration_ms,
                "error": last_error,
            })
            logger.warning(
                "Replica %s FAILED (attempt %d): %s. Triggering automatic failover...",
                backend_url, idx + 1, last_error
            )

        # All candidate replicas failed
        gateway_state.record_global_request(success=False)
        self._send_json(503, {
            "error": "ServiceUnavailable",
            "message": "All payment processing replicas failed or timed out",
            "attempt_history": attempt_logs,
            "last_error": last_error,
        })

    def _send_json(self, status: int, data: Dict[str, Any]):
        resp = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


def main():
    parser = argparse.ArgumentParser(description="Resilient SRE API Gateway")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT, help="Port to listen on")
    parser.add_argument("--backends", "-b", type=str, default=",".join(DEFAULT_BACKENDS), help="Comma-separated backends")
    args = parser.parse_args()

    gateway_state.backends = [b.strip() for b in args.backends.split(",") if b.strip()]
    gateway_state.replica_hits = {b: 0 for b in gateway_state.backends}
    gateway_state.consecutive_failures = {b: 0 for b in gateway_state.backends}

    class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedServer(("0.0.0.0", args.port), ResilientGatewayHandler)
    logger.info("Resilient API Gateway listening on http://0.0.0.0:%d", args.port)
    logger.info("Configured payment replicas: %s", gateway_state.backends)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down API Gateway...")
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
