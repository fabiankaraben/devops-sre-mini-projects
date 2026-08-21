#!/usr/bin/env python3
"""
Layer 4 Backend Service Instance
Provides:
  1. HTTP and raw TCP request handling
  2. Reporting of container hostname, node ID, request counter, and timestamp
  3. Real-time HTML visual dashboard demonstrating load balancing
  4. Lightweight JSON APIs and health probe endpoints
"""

import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

START_TIME = time.time()
PORT = int(os.environ.get("PORT", "8000"))
NODE_ID = os.environ.get("NODE_ID", socket.gethostname())
NODE_COLOR = os.environ.get("NODE_COLOR", "#38bdf8")

REQUEST_COUNT = 0

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>HAProxy Layer 4 TCP Load Balancer - DevOps & SRE</title>
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
            --node-color: __NODE_COLOR__;
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
                radial-gradient(at 100% 100%, rgba(129, 140, 248, 0.08) 0px, transparent 50%);
        }

        .container {
            max-width: 900px;
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
            color: #38bdf8;
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
            background: linear-gradient(135deg, #ffffff 30%, #93c5fd 100%);
            -webkit-background-clip: text;
            background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .subtitle {
            color: var(--text-secondary);
            font-size: 1.05rem;
            max-width: 650px;
        }

        .hero-banner {
            background: var(--bg-card);
            border: 2px solid var(--node-color);
            border-radius: 16px;
            padding: 2rem;
            text-align: center;
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 1rem;
            box-shadow: 0 10px 30px -5px rgba(0, 0, 0, 0.4), 0 0 20px -5px var(--node-color);
        }

        .node-tag {
            font-size: 0.85rem;
            font-weight: 700;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.1em;
        }

        .node-name {
            font-size: 2.5rem;
            font-weight: 900;
            font-family: var(--font-mono);
            color: var(--node-color);
            letter-spacing: -0.02em;
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
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
            color: #38bdf8;
            background: rgba(0, 0, 0, 0.3);
            padding: 0.15rem 0.5rem;
            border-radius: 6px;
            border: 1px solid rgba(255, 255, 255, 0.05);
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
            <div class="badge-domain">⚖️ 02. Networking & Traffic Routing</div>
            <h1>Layer 4 TCP Load Balancer</h1>
            <p class="subtitle">High-Throughput TCP Connection Balancing with HAProxy & Active Health Probing</p>
        </header>

        <div class="hero-banner">
            <div class="node-tag">Request Handled By Backend Node</div>
            <div class="node-name">__NODE_ID__</div>
            <p style="color: var(--text-secondary); font-size: 0.95rem;">Refresh page (⌘R / F5) to watch HAProxy round-robin across backend instances</p>
        </div>

        <div class="grid">
            <div class="card">
                <div class="card-header">
                    <div class="card-title">📊 Instance Telemetry</div>
                </div>
                <div class="metric-list">
                    <div class="metric-row">
                        <span class="metric-label">Node Identifier:</span>
                        <span class="metric-value">__NODE_ID__</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Container Hostname:</span>
                        <span class="metric-value">__HOSTNAME__</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Requests on this Node:</span>
                        <span class="metric-value">#__REQUEST_COUNT__</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Service Uptime:</span>
                        <span class="metric-value">__UPTIME__s</span>
                    </div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <div class="card-title">🌐 Network Details</div>
                </div>
                <div class="metric-list">
                    <div class="metric-row">
                        <span class="metric-label">Load Balancer Mode:</span>
                        <span class="metric-value">Layer 4 (TCP)</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Balancing Algorithm:</span>
                        <span class="metric-value">Round Robin</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">HAProxy Frontend:</span>
                        <span class="metric-value">*:9000</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Stats Dashboard:</span>
                        <span class="metric-value">:8404</span>
                    </div>
                </div>
            </div>
        </div>

        <footer>
            DevOps & SRE Mini-Projects &bull; Production-Grade HAProxy Layer 4 Architecture
        </footer>
    </div>
</body>
</html>
"""


class TCPBackendHandler(BaseHTTPRequestHandler):
    server_version = "HAProxyBackend/1.0"

    def do_GET(self):
        global REQUEST_COUNT
        REQUEST_COUNT += 1
        parsed_path = self.path.split("?")[0]

        if parsed_path == "/health" or parsed_path == "/api/health":
            self.send_json_response(200, {
                "status": "healthy",
                "node_id": NODE_ID,
                "hostname": socket.gethostname(),
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        if parsed_path == "/api/info" or parsed_path == "/info":
            self.send_json_response(200, {
                "node_id": NODE_ID,
                "hostname": socket.gethostname(),
                "requests_served": REQUEST_COUNT,
                "listening_port": PORT,
                "client_address": self.client_address[0],
                "client_port": self.client_address[1],
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        # Serve Rich HTML UI
        if parsed_path == "/" or parsed_path == "/index.html":
            uptime = str(int(time.time() - START_TIME))
            html = HTML_TEMPLATE.replace("__NODE_ID__", NODE_ID) \
                                 .replace("__NODE_COLOR__", NODE_COLOR) \
                                 .replace("__HOSTNAME__", socket.gethostname()) \
                                 .replace("__REQUEST_COUNT__", str(REQUEST_COUNT)) \
                                 .replace("__UPTIME__", uptime)

            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html.encode("utf-8"))))
            self.send_header("X-Backend-Node", NODE_ID)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(html.encode("utf-8"))
            return

        # 404 handler
        self.send_json_response(404, {"error": "Not Found", "path": self.path, "node_id": NODE_ID})

    def do_HEAD(self):
        self.do_GET()

    def send_json_response(self, status_code, data):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Backend-Node", NODE_ID)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{NODE_ID}] {self.address_string()} - {format % args}\n")


def run():
    server_address = ("0.0.0.0", PORT)
    httpd = HTTPServer(server_address, TCPBackendHandler)
    print(f"[*] Backend [{NODE_ID}] listening on http://0.0.0.0:{PORT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print(f"\n[*] Shutting down backend [{NODE_ID}]...")
        httpd.server_close()


if __name__ == "__main__":
    run()
