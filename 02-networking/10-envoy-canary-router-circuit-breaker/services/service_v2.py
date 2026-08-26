#!/usr/bin/env python3
"""
Experimental Canary Backend Service (v2.0.0-canary)
Listens on port 8002. Serves the 10% canary traffic and header overrides (x-canary: true).
Provides fault injection simulation endpoints to trigger Envoy outlier detection and circuit breaking.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", 8002))
SERVICE_NAME = "service_v2"
SERVICE_VERSION = "v2.0.0-canary"

START_TIME = time.time()
REQUEST_LOG = []
SIMULATED_FAULT = {
    "enabled": False,
    "status_code": 500,
    "remaining_count": 0,
    "delay_seconds": 0.0
}

class ThreadingSimpleServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class ServiceV2Handler(BaseHTTPRequestHandler):
    server_version = "ServiceV2/2.0.0-canary"

    def _send_json(self, status_code, data, extra_headers=None):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Backend-Service", SERVICE_NAME)
        self.send_header("X-Backend-Version", SERVICE_VERSION)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Request-ID, x-canary")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self._send_json(200, {"status": "ok"})

    def _record_request(self, method, path, status_code=200):
        req_id = self.headers.get("x-request-id", f"v2-{int(time.time()*1000)}-{len(REQUEST_LOG)}")
        is_override = (self.headers.get("x-canary") == "true")
        entry = {
            "id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "method": method,
            "path": path,
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "status_code": status_code,
            "is_canary_override": is_override,
            "headers": {k: self.headers[k] for k in self.headers}
        }
        REQUEST_LOG.append(entry)
        if len(REQUEST_LOG) > 500:
            REQUEST_LOG.pop(0)
        return req_id

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        global SIMULATED_FAULT
        path_clean = self.path.split("?")[0]

        if path_clean == "/health":
            self._send_json(200, {
                "status": "healthy",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "total_requests": len(REQUEST_LOG),
                "fault_simulation": SIMULATED_FAULT
            })
            return

        if path_clean in ("/api/stats", "/stats"):
            self._send_json(200, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "total_requests": len(REQUEST_LOG),
                "fault_simulation": SIMULATED_FAULT,
                "recent_requests": REQUEST_LOG[-20:]
            })
            return

        # Check simulated delay
        if SIMULATED_FAULT["delay_seconds"] > 0:
            time.sleep(SIMULATED_FAULT["delay_seconds"])

        # Check simulated fault (500 Internal Server Error)
        if SIMULATED_FAULT["enabled"] and (SIMULATED_FAULT["remaining_count"] > 0 or SIMULATED_FAULT["remaining_count"] == -1):
            if SIMULATED_FAULT["remaining_count"] > 0:
                SIMULATED_FAULT["remaining_count"] -= 1
            code = SIMULATED_FAULT["status_code"]
            req_id = self._record_request("GET", self.path, status_code=code)
            self._send_json(code, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "error": "Simulated Canary Service Error",
                "status_code": code,
                "request_id": req_id
            })
            return

        req_id = self._record_request("GET", self.path, status_code=200)
        self._send_json(200, {
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "status": "ok",
            "message": "High-speed canary candidate response from v2.0.0",
            "tier": "experimental_canary",
            "features": ["fast_v2_engine", "optimized_json_serializer", "edge_caching"],
            "request_id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat()
        })

    def do_POST(self):
        global SIMULATED_FAULT
        path_clean = self.path.split("?")[0]
        content_len = int(self.headers.get("Content-Length", 0))
        body_raw = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else "{}"
        try:
            body_json = json.loads(body_raw)
        except Exception:
            body_json = {}

        # Simulation control endpoints
        if path_clean in ("/api/canary/simulate-fault", "/simulate-fault"):
            SIMULATED_FAULT["enabled"] = bool(body_json.get("enabled", False))
            SIMULATED_FAULT["status_code"] = int(body_json.get("status_code", 500))
            SIMULATED_FAULT["remaining_count"] = int(body_json.get("count", 10))
            self._send_json(200, {"status": "configured", "fault": SIMULATED_FAULT})
            return

        if path_clean in ("/api/canary/simulate-delay", "/simulate-delay"):
            SIMULATED_FAULT["delay_seconds"] = float(body_json.get("delay_seconds", 0.0))
            self._send_json(200, {"status": "configured", "fault": SIMULATED_FAULT})
            return

        if path_clean in ("/api/canary/reset", "/api/reset", "/reset"):
            REQUEST_LOG.clear()
            SIMULATED_FAULT = {"enabled": False, "status_code": 500, "remaining_count": 0, "delay_seconds": 0.0}
            self._send_json(200, {"status": "reset", "service": SERVICE_NAME})
            return

        # Check simulated fault on regular POST requests
        if SIMULATED_FAULT["enabled"] and (SIMULATED_FAULT["remaining_count"] > 0 or SIMULATED_FAULT["remaining_count"] == -1):
            if SIMULATED_FAULT["remaining_count"] > 0:
                SIMULATED_FAULT["remaining_count"] -= 1
            code = SIMULATED_FAULT["status_code"]
            req_id = self._record_request("POST", self.path, status_code=code)
            self._send_json(code, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "error": "Simulated Canary Service Error",
                "status_code": code,
                "request_id": req_id
            })
            return

        req_id = self._record_request("POST", self.path, status_code=201)
        self._send_json(201, {
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "status": "created",
            "message": "High-speed canary candidate response from v2.0.0",
            "request_id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat()
        })

    def log_message(self, format, *args):
        sys.stdout.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{SERVICE_NAME}] " + (format % args) + "\n")
        sys.stdout.flush()

def run():
    server = ThreadingSimpleServer(("0.0.0.0", PORT), ServiceV2Handler)
    print(f"🚀 {SERVICE_NAME} ({SERVICE_VERSION}) listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    run()
