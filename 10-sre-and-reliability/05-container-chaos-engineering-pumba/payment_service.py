#!/usr/bin/env python3
"""
payment_service.py - Downstream Payment Processing Replica Microservice
========================================================================
Simulates backend payment execution with transaction ID generation, processing latency,
and replica identity tagging to observe failover and traffic balancing during chaos.
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
from typing import Any, Dict, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("payment_service")

DEFAULT_PORT = int(os.environ.get("PORT", 8081))
REPLICA_NAME = os.environ.get("REPLICA_NAME", "payment-service-replica")


class PaymentServiceState:
    """Thread-safe state manager for backend payment replica."""

    def __init__(self, name: str):
        self.name = name
        self._lock = threading.Lock()
        self.processed_transactions = 0
        self.total_volume_usd = 0.0
        self.start_time = time.time()

    def process(self, amount: float, user_id: str) -> Dict[str, Any]:
        # Simulate base internal processing delay: 5ms - 15ms
        delay_sec = random.uniform(0.005, 0.015)
        time.sleep(delay_sec)

        with self._lock:
            self.processed_transactions += 1
            self.total_volume_usd += amount
            tx_count = self.processed_transactions

        tx_id = f"tx_{self.name}_{int(time.time())}_{tx_count:05d}"
        return {
            "status": "APPROVED",
            "transaction_id": tx_id,
            "replica": self.name,
            "amount": amount,
            "user_id": user_id,
            "processed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "latency_ms": round(delay_sec * 1000.0, 2),
        }

    def get_stats(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "replica": self.name,
                "status": "HEALTHY",
                "uptime_seconds": round(time.time() - self.start_time, 1),
                "processed_transactions": self.processed_transactions,
                "total_volume_usd": round(self.total_volume_usd, 2),
            }


state = PaymentServiceState(REPLICA_NAME)


class PaymentHTTPHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Handler for payment processing transactions and health checks."""

    def log_message(self, format_str: str, *args: Any):
        # Suppress routine logs under load
        if "GET /health" not in format_str % args and "GET /stats" not in format_str % args:
            pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path in ("/health", "/healthz"):
            self._send_json(200, {"status": "healthy", "replica": state.name})
        elif path in ("/stats", "/api/v1/stats"):
            self._send_json(200, state.get_stats())
        else:
            self._send_json(404, {"error": "NotFound", "replica": state.name})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
        try:
            body_json = json.loads(body) if body.startswith("{") else {}
        except Exception:
            body_json = {}

        if path in ("/process", "/api/v1/process"):
            amount = float(body_json.get("amount", 99.95))
            user_id = body_json.get("user_id", f"usr_{random.randint(1000, 9999)}")
            res = state.process(amount, user_id)
            self._send_json(200, res)
        else:
            self._send_json(404, {"error": "NotFound", "replica": state.name})

    def _send_json(self, status: int, data: Dict[str, Any]):
        resp = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


def main():
    parser = argparse.ArgumentParser(description="Payment Processing Replica Service")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT, help="Port to listen on")
    parser.add_argument("--replica-name", "-n", type=str, default=REPLICA_NAME, help="Replica name identifier")
    args = parser.parse_args()

    state.name = args.replica_name

    class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedServer(("0.0.0.0", args.port), PaymentHTTPHandler)
    logger.info("Payment Replica '%s' listening on http://0.0.0.0:%d", state.name, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down Payment Replica '%s'...", state.name)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
