#!/usr/bin/env python3
"""
Stable Production Backend Service (v1.0.0)
Listens on port 8001. Serves the 90% baseline production traffic forwarded by Envoy.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", 8001))
SERVICE_NAME = "service_v1"
SERVICE_VERSION = "v1.0.0"

START_TIME = time.time()
REQUEST_LOG = []

class ThreadingSimpleServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class ServiceV1Handler(BaseHTTPRequestHandler):
    server_version = "ServiceV1/1.0.0"

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

    def _record_request(self, method, path):
        req_id = self.headers.get("x-request-id", f"v1-{int(time.time()*1000)}-{len(REQUEST_LOG)}")
        entry = {
            "id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "method": method,
            "path": path,
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "headers": {k: self.headers[k] for k in self.headers}
        }
        REQUEST_LOG.append(entry)
        if len(REQUEST_LOG) > 500:
            REQUEST_LOG.pop(0)
        return req_id

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path_clean = self.path.split("?")[0]

        if path_clean == "/health":
            self._send_json(200, {
                "status": "healthy",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "total_requests": len(REQUEST_LOG)
            })
            return

        if path_clean in ("/api/stats", "/stats"):
            self._send_json(200, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "total_requests": len(REQUEST_LOG),
                "recent_requests": REQUEST_LOG[-20:]
            })
            return

        req_id = self._record_request("GET", self.path)
        self._send_json(200, {
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "status": "ok",
            "message": "Stable enterprise response from v1.0.0",
            "tier": "stable_production",
            "request_id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat()
        })

    def do_POST(self):
        path_clean = self.path.split("?")[0]

        if path_clean in ("/api/reset", "/reset"):
            REQUEST_LOG.clear()
            self._send_json(200, {"status": "reset", "service": SERVICE_NAME})
            return

        req_id = self._record_request("POST", self.path)
        self._send_json(200, {
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "status": "created",
            "message": "Stable enterprise response from v1.0.0",
            "request_id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat()
        })

    def log_message(self, format, *args):
        sys.stdout.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{SERVICE_NAME}] " + (format % args) + "\n")
        sys.stdout.flush()

def run():
    server = ThreadingSimpleServer(("0.0.0.0", PORT), ServiceV1Handler)
    print(f"🏛️  {SERVICE_NAME} ({SERVICE_VERSION}) listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    run()
