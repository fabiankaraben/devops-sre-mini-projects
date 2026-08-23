#!/usr/bin/env python3
"""
api_server.py - Target E-Commerce REST API Microservice for k6 Load Testing
===========================================================================
Simulates high-throughput production API endpoints with realistic payload models,
database processing latency, and dynamic fault injection (latency & error spikes).
"""

import argparse
import http.server
import json
import logging
import os
import random
import socketserver
import sys
import threading
import time
import urllib.parse
from typing import Any, Dict, List, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("api_server")

DEFAULT_PORT = int(os.environ.get("PORT", 8080))


class TargetAPIServerState:
    """Thread-safe state manager for the simulated E-Commerce API."""

    def __init__(self):
        self._lock = threading.Lock()
        self.injected_latency_ms: float = 0.0
        self.injected_error_rate: float = 0.0  # 0.0 to 1.0
        self.total_requests: int = 0
        self.total_errors: int = 0
        self.total_orders_created: int = 0
        self.start_time = time.time()

        # Seed realistic mock catalog
        self.products = [
            {"id": i, "name": f"Cloud Service Plan #{i}", "sku": f"SKU-PROD-{1000 + i}", "price": round(19.99 + (i * 7.5), 2), "stock": 100 + (i * 12)}
            for i in range(1, 26)
        ]

    def reset_faults(self):
        with self._lock:
            self.injected_latency_ms = 0.0
            self.injected_error_rate = 0.0
        logger.info("Fault state reset: 0ms injected latency, 0.0% error rate.")

    def set_latency(self, delay_ms: float):
        with self._lock:
            self.injected_latency_ms = max(0.0, delay_ms)
        logger.warning("FAULT INJECTED: Artificial latency set to %.1f ms.", delay_ms)

    def set_error_rate(self, rate: float):
        with self._lock:
            self.injected_error_rate = max(0.0, min(1.0, rate))
        logger.warning("FAULT INJECTED: Error rate set to %.1f%%.", rate * 100.0)

    def record_request(self, is_error: bool = False, is_order: bool = False):
        with self._lock:
            self.total_requests += 1
            if is_error:
                self.total_errors += 1
            if is_order:
                self.total_orders_created += 1

    def get_stats(self) -> Dict[str, Any]:
        with self._lock:
            uptime = round(time.time() - self.start_time, 1)
            err_pct = round((self.total_errors / max(1, self.total_requests)) * 100.0, 2)
            return {
                "uptime_seconds": uptime,
                "total_requests": self.total_requests,
                "total_errors": self.total_errors,
                "error_rate_percent": f"{err_pct}%",
                "total_orders_created": self.total_orders_created,
                "faults": {
                    "injected_latency_ms": self.injected_latency_ms,
                    "injected_error_rate": self.injected_error_rate,
                },
            }


server_state = TargetAPIServerState()


class TargetAPIRequestHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Handler for E-Commerce API endpoints and fault controllers."""

    def log_message(self, format_str: str, *args: Any):
        # Suppress routine health logs to keep load test output clean
        if "GET /health" not in format_str % args and "GET /api/v1/stats" not in format_str % args:
            pass  # Suppress per-request logging under heavy k6 load

    def _apply_faults_and_jitter(self) -> Optional[int]:
        """Apply simulated processing latency and random error injection."""
        with server_state._lock:
            latency_ms = server_state.injected_latency_ms
            error_rate = server_state.injected_error_rate

        # Base nominal processing latency: 5ms - 18ms
        base_delay_ms = random.uniform(5.0, 18.0)
        total_delay_sec = (base_delay_ms + latency_ms) / 1000.0

        if total_delay_sec > 0:
            time.sleep(total_delay_sec)

        # Probabilistic error injection
        if error_rate > 0.0 and random.random() < error_rate:
            return 500
        return None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        query_params = urllib.parse.parse_qs(parsed.query)

        # Health endpoint (no simulated delay for healthchecks)
        if path in ("/health", "/healthz"):
            server_state.record_request(is_error=False)
            self._send_json(200, {"status": "healthy", "service": "ecommerce-api", "version": "1.0.0"})
            return

        # Apply fault injection / processing latency
        fault_code = self._apply_faults_and_jitter()
        if fault_code:
            server_state.record_request(is_error=True)
            self._send_json(500, {"error": "InternalServerError", "message": "Injected database connection timeout fault"})
            return

        if path in ("/stats", "/api/v1/stats"):
            server_state.record_request(is_error=False)
            self._send_json(200, server_state.get_stats())

        elif path == "/api/v1/products":
            limit = int(query_params.get("limit", [10])[0])
            page = int(query_params.get("page", [1])[0])
            start_idx = (page - 1) * limit
            end_idx = start_idx + limit
            items = server_state.products[start_idx:end_idx]

            server_state.record_request(is_error=False)
            self._send_json(200, {
                "page": page,
                "limit": limit,
                "total_items": len(server_state.products),
                "items": items,
            })

        elif path.startswith("/api/v1/products/"):
            try:
                prod_id = int(path.split("/")[-1])
                product = next((p for p in server_state.products if p["id"] == prod_id), None)
                if product:
                    server_state.record_request(is_error=False)
                    self._send_json(200, product)
                else:
                    server_state.record_request(is_error=True)
                    self._send_json(404, {"error": "NotFound", "message": f"Product #{prod_id} does not exist"})
            except ValueError:
                server_state.record_request(is_error=True)
                self._send_json(400, {"error": "BadRequest", "message": "Invalid product ID"})

        else:
            server_state.record_request(is_error=True)
            self._send_json(404, {"error": "NotFound", "message": f"Endpoint '{path}' not found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        query_params = urllib.parse.parse_qs(parsed.query)

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
        try:
            body_json = json.loads(body) if body.startswith("{") else {}
        except Exception:
            body_json = {}

        # 1. Fault Management Endpoints
        if path == "/fault/latency":
            delay_ms = float(query_params.get("delay_ms", [body_json.get("delay_ms", 250.0)])[0])
            server_state.set_latency(delay_ms)
            self._send_json(200, {"message": f"Injected latency set to {delay_ms}ms", "faults": server_state.get_stats()["faults"]})
            return

        elif path == "/fault/errors":
            rate = float(query_params.get("rate", [body_json.get("rate", 0.20)])[0])
            server_state.set_error_rate(rate)
            self._send_json(200, {"message": f"Injected error rate set to {rate * 100:.1f}%", "faults": server_state.get_stats()["faults"]})
            return

        elif path == "/fault/reset":
            server_state.reset_faults()
            self._send_json(200, {"message": "All faults cleared", "faults": server_state.get_stats()["faults"]})
            return

        # 2. Apply simulated latency & faults
        fault_code = self._apply_faults_and_jitter()
        if fault_code:
            server_state.record_request(is_error=True)
            self._send_json(500, {"error": "TransactionFailure", "message": "Simulated payment gateway timeout"})
            return

        # 3. Business Endpoint: Orders Creation
        if path == "/api/v1/orders":
            # Simulate DB write latency: additional 10ms - 25ms
            time.sleep(random.uniform(0.010, 0.025))

            items = body_json.get("items", [{"product_id": 1, "quantity": 1}])
            user_id = body_json.get("user_id", f"usr_{random.randint(100, 999)}")
            order_id = f"ord_{int(time.time())}_{random.randint(1000, 9999)}"

            total_amount = sum(item.get("quantity", 1) * 29.99 for item in items)
            server_state.record_request(is_error=False, is_order=True)

            self._send_json(201, {
                "order_id": order_id,
                "user_id": user_id,
                "status": "CONFIRMED",
                "total_amount": round(total_amount, 2),
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })

        else:
            server_state.record_request(is_error=True)
            self._send_json(404, {"error": "NotFound", "message": f"Endpoint '{path}' not found"})

    def _send_json(self, status: int, data: Dict[str, Any]):
        resp = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


def main():
    parser = argparse.ArgumentParser(description="High-Throughput E-Commerce Target API")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT, help="Port to listen on")
    args = parser.parse_args()

    class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedServer(("0.0.0.0", args.port), TargetAPIRequestHandler)
    logger.info("Target E-Commerce API listening on http://0.0.0.0:%d", args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down API server...")
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
