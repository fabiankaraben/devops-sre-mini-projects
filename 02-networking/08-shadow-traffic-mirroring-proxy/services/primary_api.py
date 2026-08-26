#!/usr/bin/env python3
"""
Primary Production API Service (v1.0.0)
Listens on port 8001. Handles live client traffic forwarded by the Nginx reverse proxy.
Records every received request in an in-memory audit trail for traffic replication verification.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", 8001))
SERVICE_NAME = "primary-api"
SERVICE_VERSION = "v1.0.0"

# In-memory storage for audit logs and processed data
START_TIME = time.time()
AUDIT_LOG = []
ORDERS_DB = [
    {"order_id": "ORD-1001", "item": "Cloud Server Pod", "amount": 149.99, "currency": "USD", "created_at": "2026-08-25T08:00:00Z"},
    {"order_id": "ORD-1002", "item": "Load Balancer VIP", "amount": 79.50, "currency": "USD", "created_at": "2026-08-25T08:30:00Z"}
]
USERS_DB = [
    {"user_id": "USR-001", "name": "Alice SRE", "role": "Site Reliability Engineer"},
    {"user_id": "USR-002", "name": "Bob DevOps", "role": "DevOps Architect"}
]

class ThreadingSimpleServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class PrimaryAPIHandler(BaseHTTPRequestHandler):
    server_version = "PrimaryAPI/1.0.0"

    def _send_json(self, status_code, data, extra_headers=None):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Service-Name", SERVICE_NAME)
        self.send_header("X-Service-Version", SERVICE_VERSION)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Request-ID, Authorization")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self._send_json(200, {"status": "ok"})

    def _record_audit(self, method, path, body=None):
        req_id = self.headers.get("X-Request-ID", f"gen-{int(time.time() * 1000)}-{len(AUDIT_LOG)}")
        audit_entry = {
            "request_id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "method": method,
            "path": path,
            "client_ip": self.client_address[0],
            "headers": {k: self.headers[k] for k in self.headers},
            "body": body,
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION
        }
        AUDIT_LOG.append(audit_entry)
        # Keep maximum 500 entries
        if len(AUDIT_LOG) > 500:
            AUDIT_LOG.pop(0)
        return req_id

    def do_GET(self):
        req_start = time.time()
        path = self.path.split("?")[0]

        if path == "/health":
            self._send_json(200, {
                "status": "healthy",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "total_requests_handled": len(AUDIT_LOG)
            })
            return

        if path == "/api/stats":
            get_count = sum(1 for r in AUDIT_LOG if r["method"] == "GET")
            post_count = sum(1 for r in AUDIT_LOG if r["method"] == "POST")
            self._send_json(200, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "total_requests": len(AUDIT_LOG),
                "get_count": get_count,
                "post_count": post_count,
                "recent_requests": AUDIT_LOG[-100:]
            })
            return

        # Audit live API requests
        req_id = self._record_audit("GET", self.path)

        if path in ("/api/v1/orders", "/api/orders"):
            self._send_json(200, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "request_id": req_id,
                "count": len(ORDERS_DB),
                "orders": ORDERS_DB
            })
        elif path in ("/api/v1/users", "/api/users"):
            self._send_json(200, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "request_id": req_id,
                "count": len(USERS_DB),
                "users": USERS_DB
            })
        else:
            self._send_json(200, {
                "message": "Primary API received request",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "path": self.path,
                "request_id": req_id,
                "latency_ms": round((time.time() - req_start) * 1000, 2)
            })

    def do_POST(self):
        req_start = time.time()
        path = self.path.split("?")[0]

        if path == "/api/reset":
            AUDIT_LOG.clear()
            self._send_json(200, {"status": "reset", "service": SERVICE_NAME, "message": "Audit logs cleared"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body_raw = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            body_json = json.loads(body_raw)
        except Exception:
            body_json = {"raw": body_raw}

        req_id = self._record_audit("POST", self.path, body_json)

        if path in ("/api/v1/orders", "/api/orders"):
            order_entry = {
                "order_id": body_json.get("order_id", f"ORD-{len(ORDERS_DB) + 1001}"),
                "item": body_json.get("item", "Standard Cloud Item"),
                "amount": float(body_json.get("amount", 29.99)),
                "currency": body_json.get("currency", "USD"),
                "created_at": datetime.now(timezone.utc).isoformat()
            }
            ORDERS_DB.append(order_entry)
            self._send_json(201, {
                "status": "created",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "request_id": req_id,
                "order": order_entry,
                "latency_ms": round((time.time() - req_start) * 1000, 2)
            })
        elif path in ("/api/v1/users", "/api/users"):
            user_entry = {
                "user_id": body_json.get("user_id", f"USR-{len(USERS_DB) + 1:03d}"),
                "name": body_json.get("name", "New User"),
                "role": body_json.get("role", "Developer")
            }
            USERS_DB.append(user_entry)
            self._send_json(201, {
                "status": "created",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "request_id": req_id,
                "user": user_entry
            })
        else:
            self._send_json(200, {
                "status": "success",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "path": self.path,
                "request_id": req_id,
                "received_payload": body_json,
                "latency_ms": round((time.time() - req_start) * 1000, 2)
            })

    def log_message(self, format, *args):
        # Clean timestamped logging
        sys.stdout.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{SERVICE_NAME}] " + (format % args) + "\n")
        sys.stdout.flush()

def run():
    server = ThreadingSimpleServer(("0.0.0.0", PORT), PrimaryAPIHandler)
    print(f"🚀 {SERVICE_NAME} ({SERVICE_VERSION}) listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    run()
