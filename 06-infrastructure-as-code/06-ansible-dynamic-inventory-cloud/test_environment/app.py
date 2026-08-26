#!/usr/bin/env python3
"""
Lightweight HTTP microservice simulating a cloud fleet workload.
Exposes endpoints for health checks, application versioning, draining, and status metrics.
"""

import http.server
import json
import os
import socket
import sys
import time

PORT = int(os.environ.get("APP_PORT", 8080))
HOSTNAME = socket.gethostname()
ENVIRONMENT = os.environ.get("FLEET_ENVIRONMENT", "production")
ROLE = os.environ.get("FLEET_ROLE", "web")
APP_NAME = os.environ.get("FLEET_APP", "frontend")
VERSION_FILE = "/app/version.txt"
CONFIG_FILE = "/app/config.json"

START_TIME = time.time()
IS_DRAINING = False
REQUEST_COUNT = 0


def get_version():
    """Reads current version from file or fallback environment."""
    if os.path.exists(VERSION_FILE):
        try:
            with open(VERSION_FILE, "r", encoding="utf-8") as f:
                content = f.read().strip()
                if content:
                    return content
        except Exception:
            pass
    return os.environ.get("FLEET_VERSION", "1.0.0")


def get_config():
    """Reads dynamic JSON config file if present."""
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            return {"error": f"Failed to parse config: {str(e)}"}
    return {
        "app": APP_NAME,
        "environment": ENVIRONMENT,
        "role": ROLE,
        "max_connections": 100,
        "keepalive_timeout": 65,
    }


class FleetHTTPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        """Suppress standard log spam to stdout, or format cleanly."""
        sys.stdout.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} - {format % args}\n")
        sys.stdout.flush()

    def _send_json(self, status_code, data):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Fleet-Node", HOSTNAME)
        self.send_header("X-Fleet-Version", get_version())
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        global REQUEST_COUNT
        REQUEST_COUNT += 1
        current_version = get_version()

        if self.path == "/health":
            if IS_DRAINING:
                self._send_json(503, {
                    "status": "draining",
                    "healthy": False,
                    "hostname": HOSTNAME,
                    "service": APP_NAME,
                    "role": ROLE,
                    "environment": ENVIRONMENT,
                    "version": current_version,
                    "message": "Node is currently draining / under maintenance"
                })
            else:
                self._send_json(200, {
                    "status": "healthy",
                    "healthy": True,
                    "hostname": HOSTNAME,
                    "service": APP_NAME,
                    "role": ROLE,
                    "environment": ENVIRONMENT,
                    "version": current_version,
                    "uptime_seconds": int(time.time() - START_TIME)
                })

        elif self.path == "/version":
            self._send_json(200, {
                "hostname": HOSTNAME,
                "version": current_version,
                "role": ROLE,
                "environment": ENVIRONMENT
            })

        elif self.path == "/status" or self.path == "/":
            self._send_json(200, {
                "service": APP_NAME,
                "hostname": HOSTNAME,
                "environment": ENVIRONMENT,
                "role": ROLE,
                "version": current_version,
                "draining": IS_DRAINING,
                "uptime_seconds": int(time.time() - START_TIME),
                "total_requests": REQUEST_COUNT,
                "config": get_config()
            })

        else:
            self._send_json(404, {"error": "Endpoint not found", "path": self.path})

    def do_POST(self):
        global IS_DRAINING
        if self.path == "/drain/enable":
            IS_DRAINING = True
            self._send_json(200, {"message": "Node drain mode enabled", "hostname": HOSTNAME, "draining": True})
        elif self.path == "/drain/disable":
            IS_DRAINING = False
            self._send_json(200, {"message": "Node drain mode disabled", "hostname": HOSTNAME, "draining": False})
        elif self.path == "/reload":
            self._send_json(200, {
                "message": "Configuration and version reloaded successfully",
                "hostname": HOSTNAME,
                "version": get_version(),
                "config": get_config()
            })
        else:
            self._send_json(404, {"error": "Unknown POST endpoint", "path": self.path})


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), FleetHTTPHandler)
    print(f"🚀 Fleet Node Microservice started on port {PORT} (Host: {HOSTNAME}, Role: {ROLE}, Env: {ENVIRONMENT})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down Fleet Node Microservice...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
