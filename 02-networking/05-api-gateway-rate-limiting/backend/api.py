#!/usr/bin/env python3
"""
Mock REST API Backend Service
Provides:
  1. Authentication endpoints (POST /api/v1/auth/login)
  2. Resource collections (GET /api/v1/users, GET /api/v1/orders)
  3. Heavy upload endpoint (POST /api/v1/upload)
  4. Real-time rate limiting visual dashboard and health endpoints
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

START_TIME = time.time()
PORT = int(os.environ.get("PORT", "5000"))
REQUEST_COUNTER = 0

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>API Gateway Rate Limiting - DevOps & SRE</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-primary: #0a0f1d;
            --bg-card: rgba(17, 24, 39, 0.8);
            --border-card: rgba(255, 255, 255, 0.08);
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --accent-cyan: #38bdf8;
            --accent-emerald: #10b981;
            --accent-amber: #f59e0b;
            --accent-rose: #f43f5e;
            --font-main: 'Inter', system-ui, sans-serif;
            --font-mono: 'Fira Code', monospace;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: var(--font-main);
            background-color: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.5;
            min-height: 100vh;
            padding: 2rem 1rem;
            background-image: 
                radial-gradient(at 0% 0%, rgba(56, 189, 248, 0.1) 0px, transparent 50%),
                radial-gradient(at 100% 100%, rgba(244, 63, 94, 0.08) 0px, transparent 50%);
        }

        .container {
            max-width: 960px;
            margin: 0 auto;
            display: flex;
            flex-direction: column;
            gap: 1.75rem;
        }

        header {
            text-align: center;
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 0.75rem;
        }

        .badge-domain {
            display: inline-flex;
            align-items: center;
            gap: 0.5rem;
            background: rgba(56, 189, 248, 0.15);
            color: var(--accent-cyan);
            border: 1px solid rgba(56, 189, 248, 0.3);
            border-radius: 9999px;
            padding: 0.25rem 0.85rem;
            font-size: 0.8rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        h1 {
            font-size: 2.2rem;
            font-weight: 800;
            letter-spacing: -0.025em;
            background: linear-gradient(135deg, #ffffff 30%, #38bdf8 100%);
            -webkit-background-clip: text;
            background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .subtitle {
            color: var(--text-secondary);
            font-size: 1.05rem;
            max-width: 650px;
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 1.25rem;
        }

        .card {
            background: var(--bg-card);
            border: 1px solid var(--border-card);
            border-radius: 16px;
            padding: 1.5rem;
            backdrop-filter: blur(12px);
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
        }

        .card-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 1rem;
            padding-bottom: 0.75rem;
            border-bottom: 1px solid rgba(255, 255, 255, 0.06);
        }

        .card-title {
            font-size: 1rem;
            font-weight: 600;
            color: var(--text-primary);
        }

        .status-pill {
            font-size: 0.75rem;
            font-weight: 700;
            padding: 0.2rem 0.6rem;
            border-radius: 9999px;
        }

        .status-strict {
            background: rgba(244, 63, 94, 0.15);
            color: var(--accent-rose);
            border: 1px solid rgba(244, 63, 94, 0.3);
        }

        .status-standard {
            background: rgba(56, 189, 248, 0.15);
            color: var(--accent-cyan);
            border: 1px solid rgba(56, 189, 248, 0.3);
        }

        .status-heavy {
            background: rgba(245, 158, 11, 0.15);
            color: var(--accent-amber);
            border: 1px solid rgba(245, 158, 11, 0.3);
        }

        .metric-list {
            display: flex;
            flex-direction: column;
            gap: 0.75rem;
        }

        .metric-row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 0.9rem;
        }

        .metric-label {
            color: var(--text-secondary);
        }

        .metric-value {
            font-family: var(--font-mono);
            font-weight: 600;
            background: rgba(0, 0, 0, 0.3);
            padding: 0.15rem 0.5rem;
            border-radius: 6px;
            border: 1px solid rgba(255, 255, 255, 0.05);
            color: var(--accent-cyan);
        }

        .diagram {
            background: rgba(0, 0, 0, 0.4);
            border: 1px solid var(--border-card);
            border-radius: 12px;
            padding: 1.25rem;
            font-family: var(--font-mono);
            font-size: 0.85rem;
            line-height: 1.6;
            color: #cbd5e1;
            overflow-x: auto;
        }

        footer {
            text-align: center;
            font-size: 0.85rem;
            color: var(--text-secondary);
            margin-top: 1rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="badge-domain">🛡️ 02. Networking & Traffic Routing</div>
            <h1>API Gateway Rate Limiter</h1>
            <p class="subtitle">Shared-Memory Leaky-Bucket Rate Limiting, Burst Buffers & JSON Error Handling</p>
        </header>

        <div class="card">
            <div class="card-header">
                <div class="card-title">🌊 Leaky-Bucket Architecture</div>
            </div>
            <div class="diagram">
Client Request Stream (Bursts) ──▶ [ Nginx Shared Memory Zone ]
                                      │
                                      ├──▶ In-Capacity / Burst Allowed ──▶ Forward to [ Downstream API ] (HTTP 200)
                                      │
                                      └──▶ Bucket Overflow (Excess)    ──▶ Intercepted: <span style="color:#f43f5e;font-weight:bold;">HTTP 429 Too Many Requests</span>
            </div>
        </div>

        <div class="grid">
            <div class="card">
                <div class="card-header">
                    <div class="card-title">🔑 Auth Rate Zone</div>
                    <div class="status-pill status-strict">Strict Protection</div>
                </div>
                <div class="metric-list">
                    <div class="metric-row">
                        <span class="metric-label">Target Route:</span>
                        <span class="metric-value">/api/v1/auth/*</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Rate Limit:</span>
                        <span class="metric-value">2 req / sec</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Burst Allowance:</span>
                        <span class="metric-value">3 requests</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Purpose:</span>
                        <span class="metric-value">Brute-force Shield</span>
                    </div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <div class="card-title">🌐 General API Zone</div>
                    <div class="status-pill status-standard">Standard API</div>
                </div>
                <div class="metric-list">
                    <div class="metric-row">
                        <span class="metric-label">Target Route:</span>
                        <span class="metric-value">/api/v1/*</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Rate Limit:</span>
                        <span class="metric-value">10 req / sec</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Burst Allowance:</span>
                        <span class="metric-value">10 requests</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Queue Behavior:</span>
                        <span class="metric-value">Immediate (nodelay)</span>
                    </div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <div class="card-title">📦 Upload Limit Zone</div>
                    <div class="status-pill status-heavy">Heavy Payload</div>
                </div>
                <div class="metric-list">
                    <div class="metric-row">
                        <span class="metric-label">Target Route:</span>
                        <span class="metric-value">/api/v1/upload</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Rate Limit:</span>
                        <span class="metric-value">1 req / sec</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Max Body Size:</span>
                        <span class="metric-value">1 MB (HTTP 413)</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Requests Processed:</span>
                        <span class="metric-value">#__COUNTER__</span>
                    </div>
                </div>
            </div>
        </div>

        <footer>
            DevOps & SRE Mini-Projects &bull; Production API Gateway Architecture
        </footer>
    </div>
</body>
</html>
"""


class MockAPIHandler(BaseHTTPRequestHandler):
    server_version = "DownstreamAPI/1.0"

    def do_GET(self):
        global REQUEST_COUNTER
        REQUEST_COUNTER += 1
        parsed_path = self.path.split("?")[0]

        if parsed_path == "/health" or parsed_path == "/gateway-health":
            self.send_json(200, {
                "status": "healthy",
                "service": "downstream-api",
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        if parsed_path == "/api/v1/users":
            users = [
                {"id": 1, "name": "Alice Developer", "role": "DevOps Engineer", "active": True},
                {"id": 2, "name": "Bob Reliability", "role": "SRE Lead", "active": True},
                {"id": 3, "name": "Carol Security", "role": "SecOps Specialist", "active": False}
            ]
            self.send_json(200, {
                "data": users,
                "count": len(users),
                "request_id": REQUEST_COUNTER,
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        if parsed_path == "/api/v1/orders":
            orders = [
                {"id": "ORD-101", "item": "Kubernetes Cluster Node", "amount": 450.00, "status": "completed"},
                {"id": "ORD-102", "item": "Cloud Load Balancer", "amount": 120.00, "status": "active"},
                {"id": "ORD-103", "item": "SSL Wildcard Certificate", "amount": 80.00, "status": "pending"}
            ]
            self.send_json(200, {
                "data": orders,
                "count": len(orders),
                "request_id": REQUEST_COUNTER,
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        # Dashboard UI
        if parsed_path == "/" or parsed_path == "/index.html":
            html = HTML_TEMPLATE.replace("__COUNTER__", str(REQUEST_COUNTER))
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html.encode("utf-8"))))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(html.encode("utf-8"))
            return

        self.send_json(404, {"error": "Endpoint Not Found", "path": self.path})

    def do_POST(self):
        global REQUEST_COUNTER
        REQUEST_COUNTER += 1
        parsed_path = self.path.split("?")[0]
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length) if content_length > 0 else b""

        if parsed_path == "/api/v1/auth/login":
            try:
                payload = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            except Exception:
                payload = {}

            username = payload.get("username", "guest")
            self.send_json(200, {
                "status": "authenticated",
                "user": username,
                "token": f"jwt-mock-token-session-{REQUEST_COUNTER}",
                "expires_in": 3600,
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        if parsed_path == "/api/v1/upload":
            self.send_json(200, {
                "status": "uploaded",
                "bytes_received": len(body_bytes),
                "message": "File payload successfully accepted within size limits.",
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        self.send_json(404, {"error": "Endpoint Not Found", "path": self.path})

    def do_HEAD(self):
        self.do_GET()

    def send_json(self, status_code, data):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} - {format % args}\n")


def run():
    server_address = ("0.0.0.0", PORT)
    httpd = HTTPServer(server_address, MockAPIHandler)
    print(f"[*] Downstream API service listening on http://0.0.0.0:{PORT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Shutting down API service...")
        httpd.server_close()


if __name__ == "__main__":
    run()
