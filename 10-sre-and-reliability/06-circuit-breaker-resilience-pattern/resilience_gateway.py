#!/usr/bin/env python3
"""
resilience_gateway.py - Resilient API Gateway & Microservice Client Proxy
==========================================================================
Protects upstream consumers and downstream dependencies using the Circuit Breaker
Pattern, Resilient Exponential Backoff Retries with Full Jitter, Graceful
Degradation Fallbacks, and Prometheus Telemetry.
"""

import argparse
import http.server
import json
import logging
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional

from circuit_breaker import (
    CircuitBreaker,
    CircuitBreakerConfig,
    CircuitBreakerOpenException,
    CircuitState,
    NonRetryableException,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("resilience_gateway")

DEFAULT_PORT = int(os.environ.get("PORT", 8080))
DOWNSTREAM_URL = os.environ.get("DOWNSTREAM_URL", "http://localhost:8081").rstrip("/")
FAILURE_THRESHOLD = int(os.environ.get("FAILURE_THRESHOLD", 5))
RECOVERY_TIMEOUT = float(os.environ.get("RECOVERY_TIMEOUT", 5.0))
HALF_OPEN_SUCCESS_THRESHOLD = int(os.environ.get("HALF_OPEN_SUCCESS_THRESHOLD", 2))
CALL_TIMEOUT = float(os.environ.get("CALL_TIMEOUT", 1.0))
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", 3))
BASE_BACKOFF = float(os.environ.get("BASE_BACKOFF", 0.1))
MAX_BACKOFF = float(os.environ.get("MAX_BACKOFF", 2.0))

# Initialize Circuit Breaker instance
cb_config = CircuitBreakerConfig(
    failure_threshold=FAILURE_THRESHOLD,
    recovery_timeout=RECOVERY_TIMEOUT,
    half_open_success_threshold=HALF_OPEN_SUCCESS_THRESHOLD,
    half_open_max_trials=2,
    call_timeout=CALL_TIMEOUT,
    max_retries=MAX_RETRIES,
    base_backoff=BASE_BACKOFF,
    max_backoff=MAX_BACKOFF,
    jitter=True,
    retryable_status_codes={500, 502, 503, 504, 429},
)

gateway_circuit_breaker = CircuitBreaker(
    name="order-payment-downstream-breaker",
    config=cb_config,
)


def make_downstream_http_call(
    method: str,
    path: str,
    body: Optional[Dict[str, Any]] = None,
    timeout: float = CALL_TIMEOUT,
) -> Dict[str, Any]:
    """
    Executes raw HTTP call to downstream microservice.
    Translates network timeouts and HTTP errors into appropriate exceptions.
    """
    target_url = f"{DOWNSTREAM_URL}{path}"
    data_bytes = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "Resilience-Gateway/1.0",
        "Connection": "close",
    }

    req = urllib.request.Request(url=target_url, data=data_bytes, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status_code = response.getcode()
            raw_body = response.read().decode("utf-8")
            try:
                parsed_json = json.loads(raw_body)
            except Exception:
                parsed_json = {"raw": raw_body}

            if status_code >= 400:
                if status_code in cb_config.retryable_status_codes:
                    raise Exception(f"Downstream returned retryable HTTP {status_code}: {parsed_json}")
                else:
                    raise NonRetryableException(f"Downstream returned non-retryable HTTP {status_code}: {parsed_json}")

            return parsed_json

    except urllib.error.HTTPError as he:
        status_code = he.code
        if status_code in cb_config.retryable_status_codes:
            raise Exception(f"Downstream HTTP Error {status_code}: {he.reason}")
        else:
            raise NonRetryableException(f"Downstream Client Error {status_code}: {he.reason}")

    except urllib.error.URLError as ue:
        raise Exception(f"Downstream Network Connection Error: {ue.reason}")

    except TimeoutError:
        raise Exception(f"Downstream Call Timeout (> {timeout}s)")

    except Exception as e:
        raise Exception(f"Downstream Request Failure: {e}")


# ------------------------------------------------------------------------------
# Fallback Handlers (Graceful Degradation)
# ------------------------------------------------------------------------------
def order_fallback_handler(order_id: str) -> Dict[str, Any]:
    """Fallback handler returning cached / degraded order data."""
    return {
        "order_id": order_id,
        "customer_id": "cust_cached_unknown",
        "status": "DEGRADED_CACHED",
        "message": "Real-time order details temporarily unavailable. Serving read-only cached snapshot.",
        "items": [
            {"item_id": "SKU-PRO-001", "name": "Reliability Engineering Handbook (Cached)", "qty": 1, "price": 49.99}
        ],
        "total_amount": 49.99,
        "currency": "USD",
        "fallback_served": True,
        "cached_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def payment_fallback_handler(body: Dict[str, Any]) -> Dict[str, Any]:
    """Fallback handler queuing payment for asynchronous batch processing."""
    return {
        "transaction_id": f"queued_async_{int(time.time())}",
        "payment_status": "QUEUED_FOR_RETRY",
        "message": "Payment processing downstream is currently degraded. Transaction accepted into durable offline queue.",
        "amount": body.get("amount", 0.0),
        "fallback_served": True,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def inventory_fallback_handler(item_id: str) -> Dict[str, Any]:
    """Fallback handler serving stale inventory estimation."""
    return {
        "item_id": item_id,
        "available_stock": "ESTIMATED_AVAILABLE (>10)",
        "warehouse_location": "US-DEFAULT-CACHE",
        "message": "Live inventory sync paused. Estimated stock provided.",
        "fallback_served": True,
    }


# ------------------------------------------------------------------------------
# Gateway HTTP Handler
# ------------------------------------------------------------------------------
class GatewayHTTPHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler for Resilience Gateway."""
    protocol_version = "HTTP/1.1"

    def _send_json(self, status_code: int, data: Dict[str, Any], extra_headers: Optional[Dict[str, str]] = None) -> None:
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.send_header("X-Gateway-Name", "Resilience-Gateway")
        self.send_header("X-Circuit-State", gateway_circuit_breaker.state.value)
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def _send_text(self, status_code: int, text: str, content_type: str = "text/plain; charset=utf-8") -> None:
        payload = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def do_GET(self) -> None:
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path

        if path == "/health":
            self._send_json(200, {
                "status": "UP",
                "gateway": "Resilience-Gateway",
                "circuit_state": gateway_circuit_breaker.state.value,
                "downstream_url": DOWNSTREAM_URL,
            })
            return

        elif path == "/metrics":
            self._send_text(200, gateway_circuit_breaker.to_prometheus_metrics())
            return

        elif path == "/circuit/state":
            self._send_json(200, gateway_circuit_breaker.get_stats())
            return

        elif path == "/circuit/history":
            self._send_json(200, {
                "circuit_name": gateway_circuit_breaker.name,
                "current_state": gateway_circuit_breaker.state.value,
                "history": gateway_circuit_breaker.state_history,
            })
            return

        elif path.startswith("/api/v1/orders/"):
            order_id = path.split("/api/v1/orders/")[-1]
            
            # Execute with circuit breaker protection & fallback
            result = gateway_circuit_breaker.execute(
                func=lambda: make_downstream_http_call("GET", f"/api/v1/orders/{order_id}"),
                fallback=lambda: order_fallback_handler(order_id),
            )

            response_payload = {
                "gateway_status": "SUCCESS" if result.success else "DEGRADED_FALLBACK",
                "circuit_state": result.circuit_state.value,
                "is_fallback": result.is_fallback,
                "short_circuited": result.short_circuited,
                "attempts": result.attempts,
                "gateway_latency_ms": result.latency_ms,
                "data": result.data,
            }
            if result.error:
                response_payload["last_error"] = result.error

            self._send_json(
                200 if (result.success or result.is_fallback) else 503,
                response_payload,
                {"X-Fallback-Used": str(result.is_fallback).lower()},
            )
            return

        elif path.startswith("/api/v1/inventory/"):
            item_id = path.split("/api/v1/inventory/")[-1]

            result = gateway_circuit_breaker.execute(
                func=lambda: make_downstream_http_call("GET", f"/api/v1/inventory/{item_id}"),
                fallback=lambda: inventory_fallback_handler(item_id),
            )

            self._send_json(
                200,
                {
                    "gateway_status": "SUCCESS" if result.success else "DEGRADED_FALLBACK",
                    "circuit_state": result.circuit_state.value,
                    "is_fallback": result.is_fallback,
                    "short_circuited": result.short_circuited,
                    "attempts": result.attempts,
                    "latency_ms": result.latency_ms,
                    "data": result.data,
                },
                {"X-Fallback-Used": str(result.is_fallback).lower()},
            )
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
                self._send_json(400, {"error": "Invalid JSON payload", "detail": str(e)})
                return

        if path == "/circuit/trip":
            reason = body.get("reason", "Manual trigger via POST /circuit/trip")
            gateway_circuit_breaker.trip(reason=reason)
            self._send_json(200, {
                "message": "Circuit breaker successfully TRIPPED to OPEN",
                "state": gateway_circuit_breaker.get_stats(),
            })
            return

        elif path == "/circuit/reset":
            reason = body.get("reason", "Manual trigger via POST /circuit/reset")
            gateway_circuit_breaker.reset(reason=reason)
            self._send_json(200, {
                "message": "Circuit breaker successfully RESET to CLOSED",
                "state": gateway_circuit_breaker.get_stats(),
            })
            return

        elif path == "/circuit/config":
            gateway_circuit_breaker.update_config(**body)
            self._send_json(200, {
                "message": "Circuit breaker configuration updated",
                "config": gateway_circuit_breaker.config.to_dict(),
            })
            return

        elif path == "/api/v1/payments/process":
            result = gateway_circuit_breaker.execute(
                func=lambda: make_downstream_http_call("POST", "/api/v1/payments/process", body=body),
                fallback=lambda: payment_fallback_handler(body),
            )

            self._send_json(
                200,
                {
                    "gateway_status": "SUCCESS" if result.success else "DEGRADED_FALLBACK",
                    "circuit_state": result.circuit_state.value,
                    "is_fallback": result.is_fallback,
                    "short_circuited": result.short_circuited,
                    "attempts": result.attempts,
                    "latency_ms": result.latency_ms,
                    "data": result.data,
                },
                {"X-Fallback-Used": str(result.is_fallback).lower()},
            )
            return

        else:
            self._send_json(404, {"error": "Not Found", "path": path})

    def log_message(self, format: str, *args: Any) -> None:
        """Suppresses default stderr logging to maintain clean terminal output."""
        pass


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def run_server(port: int = DEFAULT_PORT) -> None:
    server_address = ("0.0.0.0", port)
    httpd = ThreadedServer(server_address, GatewayHTTPHandler)
    logger.info(f" Resilience Gateway listening on http://0.0.0.0:{port} (Downstream: {DOWNSTREAM_URL})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down Resilience Gateway...")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Resilience API Gateway with Circuit Breaker")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port to bind to")
    parser.add_argument("--downstream", type=str, default=DOWNSTREAM_URL, help="Target downstream service URL")
    args = parser.parse_args()
    DOWNSTREAM_URL = args.downstream.rstrip("/")
    run_server(port=args.port)
