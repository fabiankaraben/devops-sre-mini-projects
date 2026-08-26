#!/usr/bin/env python3
"""
Multi-Region Application Microservice (Primary & Secondary DR)
==============================================================
Lightweight HTTP microservice simulating a regional workload in AWS
(us-east-1 Primary or us-west-2 Standby DR).

Includes health probes for Route 53, data storage with simulated S3 CRR,
and chaos endpoints to trigger controlled regional outages.
"""

import json
import logging
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Configure logging
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] [%(levelname)s] %(message)s")
logger = logging.getLogger("MultiRegionApp")

REGION_NAME = os.environ.get("REGION_NAME", "us-east-1")
REGION_ROLE = os.environ.get("REGION_ROLE", "PRIMARY")  # PRIMARY or SECONDARY_DR
S3_BUCKET = os.environ.get("S3_BUCKET", f"bucket-{REGION_NAME}")
PORT = int(os.environ.get("PORT", "8080"))

# State
IS_HEALTHY = True
DATA_STORE = {}
DATA_LOCK = threading.Lock()
REQUEST_COUNT = 0
START_TIME = time.time()


class RegionalAppHandler(BaseHTTPRequestHandler):
    """HTTP Request Handler for Regional Microservice."""

    server_version = f"RegionalApp/{REGION_NAME}"

    def log_message(self, format, *args):
        sys.stdout.write(f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}] [{REGION_NAME}] {self.address_string()} - {format % args}\n")
        sys.stdout.flush()

    def _send_json(self, status_code: int, data: dict):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Region", REGION_NAME)
        self.send_header("X-Region-Role", REGION_ROLE)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, status_code: int, html: str):
        payload = html.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Region", REGION_NAME)
        self.send_header("X-Region-Role", REGION_ROLE)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        global REQUEST_COUNT
        REQUEST_COUNT += 1
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        # 1. Route 53 Health Check Endpoint
        if path == "/health":
            if IS_HEALTHY:
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "status": "HEALTHY",
                        "region": REGION_NAME,
                        "role": REGION_ROLE,
                        "uptime_seconds": round(time.time() - START_TIME, 2),
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    },
                )
            else:
                self._send_json(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {
                        "status": "UNHEALTHY",
                        "error": "Simulated regional datacenter failure / power outage",
                        "region": REGION_NAME,
                        "role": REGION_ROLE,
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    },
                )
            return

        # 2. Regional Info Endpoint
        if path == "/api/info":
            self._send_json(
                HTTPStatus.OK,
                {
                    "region": REGION_NAME,
                    "role": REGION_ROLE,
                    "is_healthy": IS_HEALTHY,
                    "s3_bucket": S3_BUCKET,
                    "total_requests": REQUEST_COUNT,
                    "items_in_store": len(DATA_STORE),
                    "uptime_seconds": round(time.time() - START_TIME, 2),
                },
            )
            return

        # 3. Data Query Endpoint (S3 replication view)
        if path == "/api/data":
            with DATA_LOCK:
                items = list(DATA_STORE.values())
            self._send_json(
                HTTPStatus.OK,
                {
                    "region": REGION_NAME,
                    "role": REGION_ROLE,
                    "s3_bucket": S3_BUCKET,
                    "count": len(items),
                    "items": items,
                },
            )
            return

        # 4. Interactive Regional UI
        if path in ("", "/index.html"):
            color = "#22c55e" if REGION_ROLE == "PRIMARY" else "#8b5cf6"
            status_badge = '<span style="color:#22c55e;font-weight:bold;">🟢 HEALTHY</span>' if IS_HEALTHY else '<span style="color:#ef4444;font-weight:bold;">🔴 OUTAGE INJECTED</span>'

            html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>AWS Multi-Region App ({REGION_NAME})</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f172a; color: #f8fafc; padding: 30px; }}
        .card {{ background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 24px; max-width: 600px; margin: 0 auto; }}
        h1 {{ color: {color}; margin-top: 0; }}
        .btn {{ padding: 10px 16px; border-radius: 6px; border: none; font-weight: bold; cursor: pointer; margin-right: 8px; }}
        .btn-fail {{ background: #ef4444; color: white; }}
        .btn-heal {{ background: #22c55e; color: white; }}
    </style>
</head>
<body>
    <div class="card">
        <h1>🌐 Region: {REGION_NAME} ({REGION_ROLE})</h1>
        <p>Status: {status_badge}</p>
        <p>S3 Bucket: <code>{S3_BUCKET}</code></p>
        <p>Requests Handled: <strong>{REQUEST_COUNT}</strong></p>
        <hr style="border-color:#334155;margin:20px 0;">
        <h3>Chaos Engineering Controls</h3>
        <button class="btn btn-fail" onclick="fetch('/chaos/fail', {{method:'POST'}}).then(()=>location.reload())">💥 Inject Outage</button>
        <button class="btn btn-heal" onclick="fetch('/chaos/restore', {{method:'POST'}}).then(()=>location.reload())">🛡️ Restore Health</button>
    </div>
</body>
</html>"""
            self._send_html(HTTPStatus.OK, html)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Endpoint not found", "path": self.path})

    def do_POST(self):
        global IS_HEALTHY
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        # Chaos Trigger: Fail
        if path == "/chaos/fail":
            IS_HEALTHY = False
            logger.warning(f"💥 CHAOS TRIGGERED: Regional outage simulated in {REGION_NAME} ({REGION_ROLE})")
            self._send_json(HTTPStatus.OK, {"status": "OUTAGE_SIMULATED", "region": REGION_NAME, "health": "UNHEALTHY"})
            return

        # Chaos Trigger: Restore
        if path == "/chaos/restore":
            IS_HEALTHY = True
            logger.info(f"🛡️ CHAOS CLEARED: Health restored in {REGION_NAME} ({REGION_ROLE})")
            self._send_json(HTTPStatus.OK, {"status": "RESTORED", "region": REGION_NAME, "health": "HEALTHY"})
            return

        # Ingest Data
        if path == "/api/data":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
            try:
                payload = json.loads(body)
            except Exception:
                payload = {"raw": body}

            item_id = str(payload.get("id", f"item-{int(time.time() * 1000)}"))
            record = {
                "id": item_id,
                "data": payload,
                "created_at_region": REGION_NAME,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "replication_status": "COMPLETED",
            }

            with DATA_LOCK:
                DATA_STORE[item_id] = record

            logger.info(f"Stored object '{item_id}' in s3://{S3_BUCKET}")
            self._send_json(HTTPStatus.CREATED, {"message": "Data stored", "record": record})
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Endpoint not found"})


def run_server(port: int = PORT):
    server_address = ("", port)
    httpd = ThreadingHTTPServer(server_address, RegionalAppHandler)
    print(f"🚀 Multi-Region App started for region '{REGION_NAME}' ({REGION_ROLE}) on port {port}...")
    print(f"   S3 Bucket: {S3_BUCKET}")
    sys.stdout.flush()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print(f"\n🛑 Shutting down {REGION_NAME} app...")
        httpd.server_close()


if __name__ == "__main__":
    port_arg = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else PORT
    run_server(port=port_arg)
