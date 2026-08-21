#!/usr/bin/env python3
"""
Mock Dynamic API Backend
------------------------
A lightweight, zero-dependency HTTP server built with the Python standard library.
Serves dynamic JSON endpoints and inspects incoming headers to demonstrate
how Nginx reverse proxies pass headers (X-Real-IP, X-Forwarded-For, Host, etc.).

Endpoints:
  GET  /health              - Health check status and uptime metrics
  GET  /info                - Details about received request headers and client IP
  GET  /time                - Current server UTC and Unix timestamps
  GET  /data                - Sample simulated backend dataset
  GET  /simulate-error?code - Simulates HTTP error status (500, 502, 503, etc.)
  POST /echo                - Echoes back request body, query params, and headers
"""

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Server start time for uptime tracking
START_TIME = time.time()


class MockAPIHandler(BaseHTTPRequestHandler):
    server_version = "MockAPI/1.0"

    def _send_json_response(self, status_code: int, data: dict, custom_headers: dict = None):
        """Helper to serialize dict to JSON and send HTTP response."""
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Backend-Server", "Python-Mock-API")
        
        if custom_headers:
            for key, value in custom_headers.items():
                self.send_header(key, value)
                
        self.end_headers()
        self.wfile.write(payload)

    def _send_error_response(self, status_code: int, message: str):
        """Helper to send JSON error payload."""
        data = {
            "error": True,
            "status_code": status_code,
            "message": message,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
        self._send_json_response(status_code, data)

    def log_message(self, format, *args):
        """Format server request logs to standard output."""
        sys.stdout.write(f"[{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}] "
                         f"{self.address_string()} - {format % args}\n")
        sys.stdout.flush()

    def do_GET(self):
        """Handle HTTP GET requests."""
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")
        query_params = parse_qs(parsed_url.query)

        # Normalize root path to empty string or /
        if path == "":
            path = "/"

        # 1. Health check endpoint
        if path in ("/health", "/"):
            uptime = round(time.time() - START_TIME, 2)
            self._send_json_response(200, {
                "status": "healthy",
                "service": "mock-api",
                "uptime_seconds": uptime,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "endpoints_available": [
                    "/health",
                    "/info",
                    "/time",
                    "/data",
                    "/simulate-error?code=500",
                    "/echo"
                ]
            })

        # 2. Info & Proxy Header Inspection endpoint
        elif path == "/info":
            # Extract all received headers
            received_headers = {k: v for k, v in self.headers.items()}
            
            # Inspect proxy-specific headers forwarded by Nginx
            proxy_headers = {
                "host": self.headers.get("Host", ""),
                "x_real_ip": self.headers.get("X-Real-IP", ""),
                "x_forwarded_for": self.headers.get("X-Forwarded-For", ""),
                "x_forwarded_proto": self.headers.get("X-Forwarded-Proto", ""),
                "x_forwarded_host": self.headers.get("X-Forwarded-Host", ""),
                "x_forwarded_port": self.headers.get("X-Forwarded-Port", "")
            }

            self._send_json_response(200, {
                "service": "Mock Dynamic API Backend",
                "version": "1.0.0",
                "client_address": f"{self.client_address[0]}:{self.client_address[1]}",
                "proxy_detected": bool(proxy_headers.get("x_forwarded_for") or proxy_headers.get("x_real_ip")),
                "proxy_headers": proxy_headers,
                "all_received_headers": received_headers,
                "timestamp": datetime.now(timezone.utc).isoformat()
            })

        # 3. Dynamic Server Time endpoint
        elif path == "/time":
            now = datetime.now(timezone.utc)
            self._send_json_response(200, {
                "utc_iso": now.isoformat(),
                "utc_formatted": now.strftime("%A, %B %d, %Y %H:%M:%S UTC"),
                "epoch_timestamp": time.time(),
                "timezone": "UTC"
            })

        # 4. Sample dynamic dataset endpoint
        elif path == "/data":
            # Dynamic mock items payload
            items = [
                {"id": 1, "name": "Edge Reverse Proxy", "category": "Networking", "status": "active", "throughput_mbps": 450.2},
                {"id": 2, "name": "Gzip Compression Filter", "category": "Optimization", "status": "enabled", "ratio": "68%"},
                {"id": 3, "name": "Aggressive Browser Caching", "category": "Performance", "status": "active", "max_age_days": 365},
                {"id": 4, "name": "Upstream Load Balancer", "category": "Routing", "status": "healthy", "healthy_nodes": 3},
                {"id": 5, "name": "Custom Error Handler", "category": "Reliability", "status": "active", "handled_codes": [404, 500, 502, 503]}
            ]
            self._send_json_response(200, {
                "count": len(items),
                "items": items,
                "source": "dynamic-python-backend",
                "generated_at": datetime.now(timezone.utc).isoformat()
            })

        # 5. Error simulation endpoint
        elif path == "/simulate-error":
            code_param = query_params.get("code", ["500"])[0]
            try:
                status_code = int(code_param)
            except ValueError:
                status_code = 500
                
            self._send_error_response(
                status_code,
                f"Simulated HTTP {status_code} error from upstream backend."
            )

        # 6. Route not found
        else:
            self._send_error_response(404, f"API route '{parsed_url.path}' not found.")

    def do_HEAD(self):
        """Handle HTTP HEAD requests (e.g. curl -I)."""
        # Capture headers by temporarily overriding wfile write
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")
        if path == "":
            path = "/"

        if path in ("/health", "/", "/info", "/time", "/data"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("X-Backend-Server", "Python-Mock-API")
            self.end_headers()
        elif path == "/simulate-error":
            query_params = parse_qs(parsed_url.query)
            code_param = query_params.get("code", ["500"])[0]
            try:
                status_code = int(code_param)
            except ValueError:
                status_code = 500
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("X-Backend-Server", "Python-Mock-API")
            self.end_headers()
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("X-Backend-Server", "Python-Mock-API")
            self.end_headers()

    def do_POST(self):
        """Handle HTTP POST requests (e.g. echo)."""
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")
        if path == "":
            path = "/"

        if path == "/echo":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else ""
            
            # Attempt to parse body as JSON
            try:
                parsed_body = json.loads(body) if body else {}
            except json.JSONDecodeError:
                parsed_body = body

            self._send_json_response(200, {
                "message": "Payload received successfully",
                "method": "POST",
                "received_body": parsed_body,
                "headers": {k: v for k, v in self.headers.items()},
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
        else:
            self._send_error_response(404, f"POST endpoint '{parsed_url.path}' not found.")


def run_server(host: str = "0.0.0.0", port: int = 8000):
    """Start the HTTP server on specified host and port."""
    server_address = (host, port)
    httpd = HTTPServer(server_address, MockAPIHandler)
    print(f"[{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}] "
          f"Mock API Backend listening on http://{host}:{port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down Mock API server...")
        httpd.server_close()
        sys.exit(0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock Dynamic API Backend for Nginx Reverse Proxy")
    parser.add_argument("--host", default="0.0.0.0", help="Host interface to bind (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8000, help="Port to listen on (default: 8000)")
    args = parser.parse_args()

    run_server(host=args.host, port=args.port)
