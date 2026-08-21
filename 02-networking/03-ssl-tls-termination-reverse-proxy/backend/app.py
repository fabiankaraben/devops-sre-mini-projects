#!/usr/bin/env python3
"""
Lightweight Backend Application for SSL/TLS Termination Reverse Proxy.
Demonstrates:
  1. Plaintext HTTP internal communication between Nginx and Upstream
  2. Inspection of edge proxy headers (X-Forwarded-Proto, X-Real-IP, Host)
  3. Verification of SSL/TLS metadata passed down by Nginx (X-SSL-Protocol, X-SSL-Cipher)
  4. Interactive real-time diagnostics dashboard and JSON APIs
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

START_TIME = time.time()
PORT = int(os.environ.get("PORT", "8000"))

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SSL/TLS Termination Reverse Proxy - DevOps & SRE</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-primary: #0a0f1d;
            --bg-card: rgba(17, 24, 39, 0.75);
            --border-card: rgba(255, 255, 255, 0.08);
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --accent-green: #10b981;
            --accent-blue: #38bdf8;
            --accent-purple: #818cf8;
            --accent-emerald: #34d399;
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
                radial-gradient(at 0% 0%, rgba(56, 189, 248, 0.12) 0px, transparent 50%),
                radial-gradient(at 100% 100%, rgba(129, 140, 248, 0.1) 0px, transparent 50%);
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
            color: var(--accent-blue);
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
            -webkit-backdrop-filter: blur(12px);
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
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .status-pill {
            font-size: 0.75rem;
            font-weight: 700;
            padding: 0.2rem 0.6rem;
            border-radius: 9999px;
            background: rgba(16, 185, 129, 0.15);
            color: var(--accent-green);
            border: 1px solid rgba(16, 185, 129, 0.3);
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
            color: var(--accent-blue);
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

        .highlight-secure {
            color: var(--accent-green);
            font-weight: 600;
        }

        .highlight-internal {
            color: var(--accent-purple);
            font-weight: 600;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.85rem;
            font-family: var(--font-mono);
        }

        th, td {
            text-align: left;
            padding: 0.6rem 0.75rem;
            border-bottom: 1px solid rgba(255, 255, 255, 0.05);
        }

        th {
            color: var(--text-secondary);
            font-weight: 600;
            background: rgba(0, 0, 0, 0.2);
        }

        td.header-key {
            color: var(--accent-purple);
            word-break: break-all;
        }

        td.header-val {
            color: #e2e8f0;
            word-break: break-all;
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
            <div class="badge-domain">🔒 02. Networking & Traffic Routing</div>
            <h1>SSL/TLS Termination Reverse Proxy</h1>
            <p class="subtitle">Edge TLS 1.3 Termination, Strict HSTS & Clean HTTP Internal Forwarding</p>
        </header>

        <div class="card">
            <div class="card-header">
                <div class="card-title">📡 Traffic Flow Architecture</div>
                <div class="status-pill">Active & Protected</div>
            </div>
            <div class="diagram">
Client (Browser / curl)
   │  HTTPS :443 (TLS 1.3 / Modern Ciphers)
   ▼
[Nginx Reverse Proxy]  ──▶ <span class="highlight-secure">TLS Terminated & Handshake Verified</span>
   │  Plaintext HTTP :8000 (Forwarded Proxy Headers)
   ▼
[Python Backend App]   ──▶ <span class="highlight-internal">Processed Securely without SSL Overhead</span>
            </div>
        </div>

        <div class="grid">
            <div class="card">
                <div class="card-header">
                    <div class="card-title">🔐 Edge SSL/TLS Metadata</div>
                </div>
                <div class="metric-list">
                    <div class="metric-row">
                        <span class="metric-label">Negotiated Protocol:</span>
                        <span class="metric-value">__SSL_PROTOCOL__</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Active Cipher Suite:</span>
                        <span class="metric-value">__SSL_CIPHER__</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Originating Scheme:</span>
                        <span class="metric-value">__FORWARDED_PROTO__</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Client Public IP:</span>
                        <span class="metric-value">__CLIENT_IP__</span>
                    </div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <div class="card-title">⚙️ Backend Node Status</div>
                </div>
                <div class="metric-list">
                    <div class="metric-row">
                        <span class="metric-label">Internal Protocol:</span>
                        <span class="metric-value">HTTP/1.1 (Internal)</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Internal Port:</span>
                        <span class="metric-value">:__PORT__</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Service Uptime:</span>
                        <span class="metric-value">__UPTIME__s</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Server Timestamp:</span>
                        <span class="metric-value">__TIMESTAMP__</span>
                    </div>
                </div>
            </div>
        </div>

        <div class="card">
            <div class="card-header">
                <div class="card-title">📨 Received Injected Proxy Headers</div>
            </div>
            <table>
                <thead>
                    <tr>
                        <th>Header Name</th>
                        <th>Injected Value</th>
                    </tr>
                </thead>
                <tbody>
                    __HEADER_ROWS__
                </tbody>
            </table>
        </div>

        <footer>
            DevOps & SRE Mini-Projects &bull; Production-Grade SSL/TLS Termination Architecture
        </footer>
    </div>
</body>
</html>
"""


class SSLBackendHandler(BaseHTTPRequestHandler):
    server_version = "SSLBackend/1.0"

    def do_GET(self):
        parsed_path = self.path.split("?")[0]

        if parsed_path == "/health" or parsed_path == "/api/health":
            self.send_json_response(200, {
                "status": "healthy",
                "service": "ssl-tls-backend",
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
            return

        if parsed_path == "/api/tls-info":
            tls_data = {
                "ssl_terminated_at_proxy": True,
                "client_ip": self.headers.get("X-Real-IP", self.client_address[0]),
                "forwarded_for": self.headers.get("X-Forwarded-For", self.client_address[0]),
                "forwarded_proto": self.headers.get("X-Forwarded-Proto", "http"),
                "forwarded_host": self.headers.get("X-Forwarded-Host", self.headers.get("Host", "")),
                "forwarded_port": self.headers.get("X-Forwarded-Port", "8000"),
                "ssl_protocol": self.headers.get("X-SSL-Protocol", "TLSv1.3"),
                "ssl_cipher": self.headers.get("X-SSL-Cipher", "UNKNOWN"),
                "internal_connection": "HTTP/1.1 (Plaintext)",
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
            self.send_json_response(200, tls_data)
            return

        if parsed_path == "/api/headers":
            headers_dict = {k: v for k, v in self.headers.items()}
            self.send_json_response(200, {
                "headers": headers_dict,
                "client_address": self.client_address[0]
            })
            return

        # Serve Rich HTML UI
        if parsed_path == "/" or parsed_path == "/index.html":
            ssl_proto = self.headers.get("X-SSL-Protocol", "TLSv1.3")
            ssl_cipher = self.headers.get("X-SSL-Cipher", "TLS_AES_256_GCM_SHA384")
            forwarded_proto = self.headers.get("X-Forwarded-Proto", "https")
            client_ip = self.headers.get("X-Real-IP", self.client_address[0])
            uptime = str(int(time.time() - START_TIME))
            timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

            header_rows = ""
            for k, v in sorted(self.headers.items()):
                header_rows += f"<tr><td class='header-key'>{k}</td><td class='header-val'>{v}</td></tr>\n"

            html = HTML_TEMPLATE.replace("__SSL_PROTOCOL__", ssl_proto) \
                                 .replace("__SSL_CIPHER__", ssl_cipher) \
                                 .replace("__FORWARDED_PROTO__", forwarded_proto) \
                                 .replace("__CLIENT_IP__", client_ip) \
                                 .replace("__PORT__", str(PORT)) \
                                 .replace("__UPTIME__", uptime) \
                                 .replace("__TIMESTAMP__", timestamp) \
                                 .replace("__HEADER_ROWS__", header_rows)

            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html.encode("utf-8"))))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(html.encode("utf-8"))
            return

        # 404 handler
        self.send_json_response(404, {"error": "Not Found", "path": self.path})

    def do_HEAD(self):
        self.do_GET()

    def send_json_response(self, status_code, data):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, format, *args):
        # Format log message to stderr
        sys.stderr.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} - {format % args}\n")


def run():
    server_address = ("0.0.0.0", PORT)
    httpd = HTTPServer(server_address, SSLBackendHandler)
    print(f"[*] SSL/TLS Termination Backend listening on http://0.0.0.0:{PORT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Shutting down backend...")
        httpd.server_close()


if __name__ == "__main__":
    run()
