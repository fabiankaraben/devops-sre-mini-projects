#!/usr/bin/env python3
"""
downstream_service.py - Mock Downstream Microservice with Chaos Fault Injection
================================================================================
Simulates a backend business microservice (Order & Payment processing)
with controllable latency, intermittent error injection, HTTP 500/503/429
status code triggers, and live telemetry to test Circuit Breaker resilience.
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
from typing import Any, Dict, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("downstream_service")

DEFAULT_PORT = int(os.environ.get("PORT", 8081))
SERVICE_NAME = os.environ.get("SERVICE_NAME", "mock-downstream-service")


class ChaosState:
    """Thread-safe state manager for downstream service and chaos fault injection."""

    def __init__(self, name: str):
        self.name = name
        self._lock = threading.RLock()
        self.start_time = time.time()

        # Telemetry
        self.total_requests = 0
        self.successful_requests = 0
        self.injected_errors = 0
        self.injected_delays = 0

        # Chaos configuration
        self.mode = "normal"  # "normal" | "error" | "latency" | "intermittent" | "rate_limit"
        self.error_code = 500
        self.error_message = "Internal Server Error (Simulated Chaos Fault)"
        self.delay_ms = 0.0
        self.failure_rate = 0.0  # 0.0 to 1.0 for intermittent mode

    def configure_chaos(self, config: Dict[str, Any]) -> Dict[str, Any]:
        """Updates fault injection parameters."""
        with self._lock:
            if "mode" in config:
                self.mode = str(config["mode"]).lower()
            if "error_code" in config:
                self.error_code = int(config["error_code"])
            if "error_message" in config:
                self.error_message = str(config["error_message"])
            if "delay_ms" in config:
                self.delay_ms = float(config["delay_ms"])
            if "failure_rate" in config:
                self.failure_rate = float(config["failure_rate"])

            logger.warning(
                f"[{self.name}] Chaos updated: mode={self.mode}, error_code={self.error_code}, "
                f"delay_ms={self.delay_ms}, failure_rate={self.failure_rate}"
            )
            return self.get_status()

    def reset_chaos(self) -> Dict[str, Any]:
        """Resets chaos mode to normal."""
        with self._lock:
            self.mode = "normal"
            self.error_code = 500
            self.error_message = "Internal Server Error (Simulated Chaos Fault)"
            self.delay_ms = 0.0
            self.failure_rate = 0.0
            logger.info(f"[{self.name}] Chaos state reset to NORMAL.")
            return self.get_status()

    def get_status(self) -> Dict[str, Any]:
        """Returns snapshot of service health and fault injection statistics."""
        with self._lock:
            return {
                "service": self.name,
                "uptime_seconds": round(time.time() - self.start_time, 1),
                "chaos_mode": self.mode,
                "chaos_config": {
                    "error_code": self.error_code,
                    "error_message": self.error_message,
                    "delay_ms": self.delay_ms,
                    "failure_rate": self.failure_rate,
                },
                "telemetry": {
                    "total_requests": self.total_requests,
                    "successful_requests": self.successful_requests,
                    "injected_errors": self.injected_errors,
                    "injected_delays": self.injected_delays,
                },
            }

    def process_request(self) -> Tuple[bool, int, Dict[str, Any]]:
        """
        Processes an incoming request according to current chaos configuration.
        Returns: (is_success, http_status_code, response_dict)
        """
        with self._lock:
            self.total_requests += 1
            mode = self.mode
            delay = self.delay_ms
            err_code = self.error_code
            err_msg = self.error_message
            rate = self.failure_rate

        # 1. Apply Latency Injection
        if mode == "latency" and delay > 0:
            time.sleep(delay / 1000.0)
            with self._lock:
                self.injected_delays += 1

        # 2. Apply Error Injections
        if mode == "error":
            with self._lock:
                self.injected_errors += 1
            return False, err_code, {
                "error": True,
                "status_code": err_code,
                "message": err_msg,
                "service": self.name,
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }

        elif mode == "rate_limit":
            with self._lock:
                self.injected_errors += 1
            return False, 429, {
                "error": True,
                "status_code": 429,
                "message": "Too Many Requests (Rate limit exceeded)",
                "service": self.name,
                "retry_after": 2,
            }

        elif mode == "intermittent":
            if random.random() < rate:
                with self._lock:
                    self.injected_errors += 1
                return False, err_code, {
                    "error": True,
                    "status_code": err_code,
                    "message": f"Intermittent Failure (rate={rate})",
                    "service": self.name,
                }

        # 3. Normal Execution
        with self._lock:
            self.successful_requests += 1

        return True, 200, {
            "status": "SUCCESS",
            "service": self.name,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }


# Global singleton state
chaos_manager = ChaosState(name=SERVICE_NAME)


class DownstreamHTTPHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler for Downstream Service."""
    protocol_version = "HTTP/1.1"

    def _send_json(self, status_code: int, data: Dict[str, Any]) -> None:
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.send_header("X-Service-Name", SERVICE_NAME)
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def do_GET(self) -> None:
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path

        if path == "/health":
            self._send_json(200, {"status": "UP", "service": SERVICE_NAME})
            return

        elif path == "/chaos/status":
            self._send_json(200, chaos_manager.get_status())
            return

        elif path.startswith("/api/v1/orders/"):
            order_id = path.split("/api/v1/orders/")[-1]
            success, code, res = chaos_manager.process_request()
            if not success:
                self._send_json(code, res)
            else:
                res.update({
                    "order_id": order_id,
                    "customer_id": f"cust_{abs(hash(order_id)) % 1000:04d}",
                    "total_amount": 149.99,
                    "currency": "USD",
                    "status": "CONFIRMED",
                    "items": [
                        {"item_id": "SKU-PRO-001", "name": "Reliability Engineering Handbook", "qty": 1, "price": 49.99},
                        {"item_id": "SKU-SRV-002", "name": "Cloud Observability Platform", "qty": 1, "price": 100.00},
                    ],
                })
                self._send_json(200, res)
            return

        elif path.startswith("/api/v1/inventory/"):
            item_id = path.split("/api/v1/inventory/")[-1]
            success, code, res = chaos_manager.process_request()
            if not success:
                self._send_json(code, res)
            else:
                res.update({
                    "item_id": item_id,
                    "available_stock": 420,
                    "reserved_stock": 15,
                    "warehouse_location": "US-EAST-DC1",
                })
                self._send_json(200, res)
            return

        else:
            self._send_json(404, {"error": "Not Found", "path": path})

    def do_POST(self) -> None:
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path

        content_length = int(self.headers.get("Content-Length", 0))
        body = {}
        if content_length > 0:
            try:
                raw_data = self.rfile.read(content_length).decode("utf-8")
                body = json.loads(raw_data) if raw_data.strip() else {}
            except Exception as e:
                self._send_json(400, {"error": "Invalid JSON body", "detail": str(e)})
                return

        if path == "/chaos/faults":
            result = chaos_manager.configure_chaos(body)
            self._send_json(200, {"message": "Chaos configuration updated", "state": result})
            return

        elif path == "/chaos/reset":
            result = chaos_manager.reset_chaos()
            self._send_json(200, {"message": "Chaos reset to normal", "state": result})
            return

        elif path == "/api/v1/payments/process":
            success, code, res = chaos_manager.process_request()
            if not success:
                self._send_json(code, res)
            else:
                amount = body.get("amount", 99.99)
                card_last4 = body.get("card_last4", "4242")
                res.update({
                    "transaction_id": f"txn_{int(time.time())}_{random.randint(1000, 9999)}",
                    "amount": amount,
                    "card_last4": card_last4,
                    "authorization_code": "AUTH_OK_987",
                    "payment_status": "SETTLED",
                })
                self._send_json(200, res)
            return

        else:
            self._send_json(404, {"error": "Not Found", "path": path})

    def log_message(self, format: str, *args: Any) -> None:
        """Suppresses default stderr logging to keep terminal output clean."""
        pass


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def run_server(port: int = DEFAULT_PORT) -> None:
    server_address = ("0.0.0.0", port)
    httpd = ThreadedServer(server_address, DownstreamHTTPHandler)
    logger.info(f" Downstream Microservice listening on http://0.0.0.0:{port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down downstream service...")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock Downstream Microservice with Chaos Injection")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port to bind to")
    args = parser.parse_args()
    run_server(port=args.port)
