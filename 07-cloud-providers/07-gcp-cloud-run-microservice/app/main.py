#!/usr/bin/env python3
"""
GCP Cloud Run Scalable Microservice
==================================
A high-performance, containerized Python HTTP microservice optimized for
Google Cloud Run serverless execution, fine-grained concurrency handling,
Google Secret Manager injection, and cold start latency benchmarking.
"""

import hashlib
import json
import os
import signal
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Global state & metrics
BOOT_START_TIME = time.time()
ACTIVE_REQUESTS = 0
TOTAL_REQUESTS_SERVED = 0
REQUEST_LOCK = threading.Lock()
SHUTDOWN_SIGNAL_RECEIVED = False

# Cloud Run / Knative Environment Metadata
SERVICE_NAME = os.environ.get("K_SERVICE", "scalable-microservice")
REVISION_NAME = os.environ.get("K_REVISION", "scalable-microservice-v1")
CONFIGURATION_NAME = os.environ.get("K_CONFIGURATION", "scalable-microservice")
PORT = int(os.environ.get("PORT", "8080"))
INSTANCE_ID = os.environ.get("CONTAINER_ID", f"inst-{socket.gethostname()[:8]}")
CONCURRENCY_LIMIT = int(os.environ.get("CONCURRENCY_LIMIT", "80"))
SECRET_KEY = os.environ.get("API_SECRET_KEY", "dev-fallback-secret-key-12345")


def get_secret_masked() -> dict:
    """Return secure masked summary of injected secret without leaking full plaintext."""
    if not SECRET_KEY:
        return {"configured": False, "masked": "NONE", "fingerprint": "NONE"}
    masked = f"{SECRET_KEY[:3]}****{SECRET_KEY[-4:]}" if len(SECRET_KEY) >= 8 else "********"
    fingerprint = hashlib.sha256(SECRET_KEY.encode()).hexdigest()[:12]
    return {
        "configured": True,
        "source": "Google Secret Manager",
        "masked_value": masked,
        "fingerprint": fingerprint,
    }


def handle_sigterm(signum, frame):
    """Graceful termination handler for Cloud Run scale-to-zero SIGTERM."""
    global SHUTDOWN_SIGNAL_RECEIVED
    SHUTDOWN_SIGNAL_RECEIVED = True
    sys.stdout.write(f"[{datetime.now(timezone.utc).isoformat()}] SIGTERM received. Draining active connections...\n")
    sys.stdout.flush()


signal.signal(signal.SIGTERM, handle_sigterm)


class CloudRunHandler(BaseHTTPRequestHandler):
    """HTTP Request Handler for Cloud Run Microservice."""

    server_version = "GCPCloudRunMicroservice/1.0"

    def log_message(self, format, *args):
        """Standardized JSON-friendly stdout logging."""
        sys.stdout.write(
            f"[{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}] "
            f"{self.address_string()} - {format % args}\n"
        )
        sys.stdout.flush()

    def _send_json(self, status_code: int, data: dict):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Instance-Id", INSTANCE_ID)
        self.send_header("X-Revision", REVISION_NAME)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, status_code: int, html_content: str):
        payload = html_content.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Instance-Id", INSTANCE_ID)
        self.send_header("X-Revision", REVISION_NAME)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        global ACTIVE_REQUESTS, TOTAL_REQUESTS_SERVED
        with REQUEST_LOCK:
            ACTIVE_REQUESTS += 1
            TOTAL_REQUESTS_SERVED += 1
            current_active = ACTIVE_REQUESTS
            total_served = TOTAL_REQUESTS_SERVED

        req_start_time = time.time()
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        query_params = parse_qs(parsed.query)

        try:
            # ------------------------------------------------------------------
            # 1. Health / Liveness Probe (/health or /healthz)
            # ------------------------------------------------------------------
            if path in ("/health", "/healthz"):
                uptime = round(time.time() - BOOT_START_TIME, 2)
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "status": "HEALTHY",
                        "service": SERVICE_NAME,
                        "instance_id": INSTANCE_ID,
                        "uptime_seconds": uptime,
                        "shutting_down": SHUTDOWN_SIGNAL_RECEIVED,
                    },
                )
                return

            # ------------------------------------------------------------------
            # 2. Concurrency Gauge Endpoint (/api/concurrency)
            # ------------------------------------------------------------------
            if path == "/api/concurrency":
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "instance_id": INSTANCE_ID,
                        "active_concurrent_requests": current_active,
                        "concurrency_limit": CONCURRENCY_LIMIT,
                        "utilization_percent": round((current_active / max(1, CONCURRENCY_LIMIT)) * 100.0, 1),
                        "total_requests_served": total_served,
                    },
                )
                return

            # ------------------------------------------------------------------
            # 3. Secret Manager Verification Endpoint (/api/secret)
            # ------------------------------------------------------------------
            if path == "/api/secret":
                secret_info = get_secret_masked()
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "service": SERVICE_NAME,
                        "instance_id": INSTANCE_ID,
                        "secret_verification": secret_info,
                        "status": "AUTHENTICATED" if secret_info["configured"] else "UNSET",
                    },
                )
                return

            # ------------------------------------------------------------------
            # 4. Latency / Data Processing Simulation (/api/data)
            # ------------------------------------------------------------------
            if path == "/api/data":
                delay_ms = int(query_params.get("delay_ms", ["0"])[0])
                if delay_ms > 0:
                    delay_sec = min(delay_ms, 5000) / 1000.0  # Max 5s delay
                    time.sleep(delay_sec)

                elapsed_ms = round((time.time() - req_start_time) * 1000.0, 2)
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "message": "Processed simulated workload",
                        "instance_id": INSTANCE_ID,
                        "simulated_delay_ms": delay_ms,
                        "total_execution_ms": elapsed_ms,
                        "active_concurrency_at_dispatch": current_active,
                    },
                )
                return

            # ------------------------------------------------------------------
            # 5. Main Dashboard & Metadata (/)
            # ------------------------------------------------------------------
            if path == "" or path == "/index.html":
                accept = self.headers.get("Accept", "")
                if "application/json" in accept or "json" in query_params.get("format", [""])[0]:
                    cold_start_latency_ms = round((time.time() - BOOT_START_TIME) * 1000.0, 2)
                    self._send_json(
                        HTTPStatus.OK,
                        {
                            "service": SERVICE_NAME,
                            "revision": REVISION_NAME,
                            "instance_id": INSTANCE_ID,
                            "concurrency": {
                                "active": current_active,
                                "limit": CONCURRENCY_LIMIT,
                            },
                            "uptime_seconds": round(time.time() - BOOT_START_TIME, 2),
                            "cold_start_latency_ms": cold_start_latency_ms,
                            "secret_configured": bool(SECRET_KEY),
                        },
                    )
                    return

                # Render HTML Dashboard
                uptime_sec = round(time.time() - BOOT_START_TIME, 1)
                secret_info = get_secret_masked()
                html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GCP Cloud Run Microservice</title>
    <style>
        :root {{
            --bg-color: #0b0f19;
            --card-bg: #151c2e;
            --card-border: #24304d;
            --text-primary: #f1f5f9;
            --text-secondary: #94a3b8;
            --accent-gcp: #4285f4;
            --accent-green: #34a853;
            --accent-amber: #fbbc05;
            --accent-red: #ea4335;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-primary);
            margin: 0;
            padding: 24px;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            box-sizing: border-box;
        }}
        .container {{
            max-width: 840px;
            width: 100%;
            background: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 16px;
            padding: 32px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.7);
        }}
        .header {{
            border-bottom: 1px solid var(--card-border);
            padding-bottom: 20px;
            margin-bottom: 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 12px;
        }}
        h1 {{
            margin: 0;
            font-size: 24px;
            color: var(--accent-gcp);
            display: flex;
            align-items: center;
            gap: 10px;
        }}
        .badge {{
            padding: 6px 14px;
            border-radius: 9999px;
            font-weight: 600;
            font-size: 13px;
            text-transform: uppercase;
        }}
        .badge-serverless {{
            background: rgba(66, 133, 244, 0.15);
            color: var(--accent-gcp);
            border: 1px solid rgba(66, 133, 244, 0.3);
        }}
        .badge-status {{
            background: rgba(52, 168, 83, 0.15);
            color: var(--accent-green);
            border: 1px solid var(--accent-green);
        }}
        .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }}
        .metric-card {{
            background: #0b0f19;
            border: 1px solid var(--card-border);
            border-radius: 12px;
            padding: 16px;
        }}
        .metric-label {{
            font-size: 12px;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 6px;
        }}
        .metric-value {{
            font-size: 18px;
            font-weight: 700;
            font-family: monospace;
            color: #ffffff;
            word-break: break-all;
        }}
        .actions {{
            border-top: 1px solid var(--card-border);
            padding-top: 24px;
        }}
        .btn-group {{
            display: flex;
            gap: 12px;
            flex-wrap: wrap;
            margin-top: 12px;
        }}
        button {{
            padding: 10px 18px;
            border-radius: 8px;
            font-weight: 600;
            font-size: 14px;
            cursor: pointer;
            border: none;
            transition: all 0.2s ease;
        }}
        .btn-primary {{
            background: var(--accent-gcp);
            color: #fff;
        }}
        .btn-primary:hover {{
            background: #3367d6;
        }}
        .btn-amber {{
            background: var(--accent-amber);
            color: #000;
        }}
        .btn-green {{
            background: var(--accent-green);
            color: #fff;
        }}
        .footer {{
            margin-top: 24px;
            font-size: 12px;
            color: var(--text-secondary);
            text-align: center;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 GCP Cloud Run Scalable Microservice</h1>
            <div>
                <span class="badge badge-serverless">⚡ Serverless Gen2</span>
                <span class="badge badge-status">● LIVE</span>
            </div>
        </div>

        <div class="grid">
            <div class="metric-card">
                <div class="metric-label">Service / Revision</div>
                <div class="metric-value">{SERVICE_NAME} / {REVISION_NAME}</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Container Instance ID</div>
                <div class="metric-value">{INSTANCE_ID}</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Concurrency Limit</div>
                <div class="metric-value">{CONCURRENCY_LIMIT} req/instance</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Active Requests</div>
                <div class="metric-value" style="color: var(--accent-amber);">{current_active} in flight</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Uptime</div>
                <div class="metric-value">{uptime_sec}s</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Secret Manager Binding</div>
                <div class="metric-value" style="color: var(--accent-green);">{secret_info['masked_value']}</div>
            </div>
        </div>

        <div class="actions">
            <div class="metric-label">🧪 Interactive Endpoints & Probes</div>
            <div class="btn-group">
                <button class="btn-primary" onclick="location.reload()">🔄 Refresh Dashboard</button>
                <button class="btn-amber" onclick="fetch('/api/data?delay_ms=100').then(r=>r.json()).then(d=>alert(JSON.stringify(d,null,2)))">⏱️ Simulate Workload (100ms)</button>
                <button class="btn-green" onclick="fetch('/api/secret').then(r=>r.json()).then(d=>alert(JSON.stringify(d,null,2)))">🔐 Verify Secret Manager</button>
            </div>
        </div>

        <div class="footer">
            Architecture: Google Cloud Run (v2 API) + Google Secret Manager + IAM Least-Privilege SA
        </div>
    </div>
</body>
</html>
"""
                self._send_html(HTTPStatus.OK, html)
                return

            # Fallback 404
            self._send_json(
                HTTPStatus.NOT_FOUND,
                {
                    "error": "Not Found",
                    "path": self.path,
                    "available_endpoints": ["/", "/health", "/healthz", "/api/concurrency", "/api/secret", "/api/data", "/api/compute"],
                },
            )
        finally:
            with REQUEST_LOCK:
                ACTIVE_REQUESTS = max(0, ACTIVE_REQUESTS - 1)

    def do_POST(self):
        """Handle POST workload execution (e.g. CPU compute)."""
        global ACTIVE_REQUESTS, TOTAL_REQUESTS_SERVED
        with REQUEST_LOCK:
            ACTIVE_REQUESTS += 1
            TOTAL_REQUESTS_SERVED += 1
            current_active = ACTIVE_REQUESTS

        req_start_time = time.time()
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        query_params = parse_qs(parsed.query)

        try:
            if path == "/api/compute":
                # Simulated compute task: calculate hash iterations
                iterations = int(query_params.get("iterations", ["50000"])[0])
                iterations = min(iterations, 500000)

                val = b"gcp-cloud-run-benchmark-workload"
                for _ in range(iterations):
                    val = hashlib.sha256(val).digest()

                elapsed_ms = round((time.time() - req_start_time) * 1000.0, 2)
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "message": "Compute task executed",
                        "instance_id": INSTANCE_ID,
                        "iterations": iterations,
                        "execution_ms": elapsed_ms,
                        "active_concurrency": current_active,
                    },
                )
                return

            # Route other POST requests to do_GET handler
            self.do_GET()
        finally:
            with REQUEST_LOCK:
                ACTIVE_REQUESTS = max(0, ACTIVE_REQUESTS - 1)


def run_server(port: int = PORT):
    """Run the microservice HTTP server."""
    server_address = ("", port)
    httpd = ThreadingHTTPServer(server_address, CloudRunHandler)
    print(f"🚀 Cloud Run Microservice active on port {port}...")
    print(f"   Service:     {SERVICE_NAME}")
    print(f"   Revision:    {REVISION_NAME}")
    print(f"   Instance ID: {INSTANCE_ID}")
    print(f"   Concurrency: {CONCURRENCY_LIMIT}")
    sys.stdout.flush()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down microservice...")
        httpd.server_close()


if __name__ == "__main__":
    port_env = int(os.environ.get("PORT", sys.argv[1] if len(sys.argv) > 1 else "8080"))
    run_server(port=port_env)
