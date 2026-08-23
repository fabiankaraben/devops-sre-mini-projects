#!/usr/bin/env python3
"""
mock_services.py - Target Microservices & Fault Injection API for Runbook Remediation
======================================================================================
Simulates production microservice state (Worker pool, In-Memory Cache, Job Queue)
and provides fault-injection endpoints as well as remediation callback targets.
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
import urllib.parse
from typing import Any, Dict, List, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("mock_services")

DEFAULT_PORT = int(os.environ.get("PORT", 9000))


class ServiceStateManager:
    """Thread-safe state manager for simulated target microservices."""

    def __init__(self):
        self._lock = threading.Lock()
        self.reset()

    def reset(self):
        with self._lock:
            # Worker Service State
            self.worker_state = {
                "service": "worker-service",
                "status": "HEALTHY",
                "active_threads": 8,
                "hung_threads": 0,
                "cpu_percent": 18.5,
                "restart_count": 0,
                "last_restarted": None,
            }

            # Cache Service State
            self.cache_state = {
                "service": "redis-cache",
                "status": "HEALTHY",
                "memory_used_mb": 142.0,
                "memory_limit_mb": 1024.0,
                "memory_usage_percent": 13.8,
                "eviction_count": 0,
                "last_flushed": None,
            }

            # Queue Service State
            self.queue_state = {
                "service": "order-queue",
                "status": "HEALTHY",
                "replica_count": 2,
                "pending_messages": 45,
                "dead_letter_count": 0,
                "processing_rate_rps": 120,
                "last_scaled": None,
                "last_drained": None,
            }

            # Incident auto-resolution tracking
            self.resolved_incidents: List[Dict[str, Any]] = []

    # --------------------------------------------------------------------------
    # Worker Service Methods
    # --------------------------------------------------------------------------
    def hang_worker(self):
        with self._lock:
            self.worker_state["status"] = "HUNG_DEADLOCK"
            self.worker_state["hung_threads"] = 8
            self.worker_state["cpu_percent"] = 99.8
        logger.warning("FAULT INJECTED: worker-service entered HUNG_DEADLOCK state (100% CPU lock).")

    def restart_worker(self) -> Dict[str, Any]:
        with self._lock:
            self.worker_state["status"] = "HEALTHY"
            self.worker_state["hung_threads"] = 0
            self.worker_state["cpu_percent"] = 14.2
            self.worker_state["restart_count"] += 1
            self.worker_state["last_restarted"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            res = dict(self.worker_state)
        logger.info("REMEDIATION APPLIED: worker-service successfully restarted.")
        return res

    # --------------------------------------------------------------------------
    # Cache Service Methods
    # --------------------------------------------------------------------------
    def fill_cache(self):
        with self._lock:
            self.cache_state["status"] = "OUT_OF_MEMORY"
            self.cache_state["memory_used_mb"] = 988.5
            self.cache_state["memory_usage_percent"] = 96.5
        logger.warning("FAULT INJECTED: redis-cache reached 96.5% critical memory pressure.")

    def flush_cache(self) -> Dict[str, Any]:
        with self._lock:
            self.cache_state["status"] = "HEALTHY"
            self.cache_state["memory_used_mb"] = 45.0
            self.cache_state["memory_usage_percent"] = 4.4
            self.cache_state["eviction_count"] += 1
            self.cache_state["last_flushed"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            res = dict(self.cache_state)
        logger.info("REMEDIATION APPLIED: redis-cache evicted expired keys, memory dropped to 4.4%.")
        return res

    # --------------------------------------------------------------------------
    # Queue Service Methods
    # --------------------------------------------------------------------------
    def spike_queue(self):
        with self._lock:
            self.queue_state["status"] = "BACKLOG_OVERFLOW"
            self.queue_state["pending_messages"] = 48500
            self.queue_state["dead_letter_count"] = 1240
        logger.warning("FAULT INJECTED: order-queue backlog surged to 48,500 messages.")

    def scale_queue(self, target_replicas: int) -> Dict[str, Any]:
        with self._lock:
            self.queue_state["replica_count"] = target_replicas
            self.queue_state["status"] = "DRAINING_BACKLOG" if self.queue_state["pending_messages"] > 500 else "HEALTHY"
            self.queue_state["pending_messages"] = max(10, self.queue_state["pending_messages"] - (target_replicas * 5000))
            self.queue_state["processing_rate_rps"] = target_replicas * 60
            self.queue_state["last_scaled"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            res = dict(self.queue_state)
        logger.info("REMEDIATION APPLIED: order-queue scaled to %d worker replicas.", target_replicas)
        return res

    def drain_dead_letters(self) -> Dict[str, Any]:
        with self._lock:
            reprocessed = self.queue_state["dead_letter_count"]
            self.queue_state["dead_letter_count"] = 0
            self.queue_state["last_drained"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            res = dict(self.queue_state)
            res["reprocessed_count"] = reprocessed
        logger.info("REMEDIATION APPLIED: order-queue DLQ drained (%d messages reprocessed).", reprocessed)
        return res

    def record_resolved_incident(self, incident_id: str, payload: Dict[str, Any]):
        with self._lock:
            self.resolved_incidents.append({
                "incident_id": incident_id,
                "resolved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "payload": payload,
            })
        logger.info("INCIDENT RESOLVED: Callback received for incident '%s'.", incident_id)

    def get_full_state(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "worker": dict(self.worker_state),
                "cache": dict(self.cache_state),
                "queue": dict(self.queue_state),
                "resolved_incidents": list(self.resolved_incidents),
            }


state = ServiceStateManager()


class MockServicesHTTPHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler for mock service state & remediation commands."""

    def log_message(self, format_str: str, *args: Any):
        if "GET /health" not in format_str % args and "GET /status" not in format_str % args:
            logger.info("%s - %s", self.client_address[0], format_str % args)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path in ("/health", "/healthz"):
            resp = json.dumps({"status": "healthy", "service": "mock-services-target"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(resp)

        elif path in ("/status", "/api/v1/status"):
            resp = json.dumps(state.get_full_state(), indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(resp)

        elif path == "/worker/status":
            resp = json.dumps(state.worker_state, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(resp)

        elif path == "/cache/status":
            resp = json.dumps(state.cache_state, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(resp)

        elif path == "/queue/status":
            resp = json.dumps(state.queue_state, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(resp)

        elif path.startswith("/fault/"):
            fault_name = path.replace("/fault/", "").strip().lower()
            self._handle_fault(fault_name)

        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"error":"Not Found"}')

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

        if path.startswith("/fault/"):
            fault_name = path.replace("/fault/", "").strip().lower()
            self._handle_fault(fault_name)

        elif path == "/worker/restart":
            res = state.restart_worker()
            self._send_json(200, {"message": "Worker service restarted successfully", "state": res})

        elif path == "/cache/flush":
            res = state.flush_cache()
            self._send_json(200, {"message": "Cache flushed successfully", "state": res})

        elif path == "/queue/scale":
            replicas = int(query_params.get("replicas", [body_json.get("replicas", 5)])[0])
            res = state.scale_queue(replicas)
            self._send_json(200, {"message": f"Queue scaled to {replicas} replicas", "state": res})

        elif path == "/queue/drain":
            res = state.drain_dead_letters()
            self._send_json(200, {"message": "Dead-letter queue drained", "state": res})

        elif path.startswith("/pagerduty/api/v1/incidents/") and path.endswith("/resolve"):
            inc_id = path.split("/")[5]
            state.record_resolved_incident(inc_id, body_json)
            self._send_json(200, {"message": f"Incident {inc_id} marked as RESOLVED", "status": "resolved"})

        elif path == "/reset":
            state.reset()
            self._send_json(200, {"message": "State reset to initial healthy baseline", "state": state.get_full_state()})

        else:
            self._send_json(404, {"error": f"Unknown endpoint '{path}'"})

    def _handle_fault(self, fault_name: str):
        if fault_name in ("hang-worker", "hang_worker", "worker-hang"):
            state.hang_worker()
            self._send_json(200, {"message": "Fault injected: Worker service hung", "state": state.worker_state})
        elif fault_name in ("fill-cache", "fill_cache", "cache-oom"):
            state.fill_cache()
            self._send_json(200, {"message": "Fault injected: Cache memory pressure", "state": state.cache_state})
        elif fault_name in ("spike-queue", "spike_queue", "queue-backlog"):
            state.spike_queue()
            self._send_json(200, {"message": "Fault injected: Queue backlog spike", "state": state.queue_state})
        else:
            self._send_json(400, {"error": f"Unknown fault '{fault_name}'", "available": ["hang-worker", "fill-cache", "spike-queue"]})

    def _send_json(self, status: int, data: Dict[str, Any]):
        resp = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


def main():
    parser = argparse.ArgumentParser(description="Mock Services & Fault Injection Target")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT, help="Port to listen on")
    args = parser.parse_args()

    class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedServer(("0.0.0.0", args.port), MockServicesHTTPHandler)
    logger.info("Mock Target Services listening on http://0.0.0.0:%d", args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down mock services...")
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
