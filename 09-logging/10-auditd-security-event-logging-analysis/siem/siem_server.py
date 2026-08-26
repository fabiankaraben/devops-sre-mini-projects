#!/usr/bin/env python3
"""SIEM Security Operations Server & REST API.

Provides real-time ingestion, categorization, and visualization for Linux Auditd events:
- Ingestion endpoint: POST /api/events
- Alert retrieval endpoint: GET /api/alerts
- Threat statistics endpoint: GET /api/stats
- Healthcheck endpoint: GET /api/health
- Web Dashboard: GET /
"""

import http.server
import json
import os
import socketserver
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

PORT = int(os.environ.get("PORT", "9099"))
MAX_ALERTS = 200

# In-Memory Security Threat Storage
ALERTS_LOCK = threading.Lock()
ALERTS_BUFFER: List[Dict[str, Any]] = []


class SIEMRequestHandler(http.server.SimpleHTTPRequestHandler):
    """Handles REST API and dashboard requests for the SIEM platform."""

    def __init__(self, *args, **kwargs):
        self.template_path = Path(__file__).parent / "templates" / "index.html"
        super().__init__(*args, **kwargs)

    def _send_json(self, status_code: int, data: Any):
        """Helper to serialize and emit JSON responses."""
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, DELETE")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        """Handle CORS pre-flight requests."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, DELETE")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        """Handle GET requests."""
        parsed_path = self.path.split("?")[0]

        if parsed_path in ("/", "/index.html"):
            if self.template_path.is_file():
                with open(self.template_path, "rb") as f:
                    content = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            else:
                self.send_error(404, "Dashboard template not found")
            return

        if parsed_path == "/api/health":
            self._send_json(200, {
                "status": "healthy",
                "service": "audit-siem-server",
                "total_alerts": len(ALERTS_BUFFER),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            })
            return

        if parsed_path == "/api/alerts":
            with ALERTS_LOCK:
                # Return newest first
                alerts_copy = list(reversed(ALERTS_BUFFER))
            self._send_json(200, alerts_copy)
            return

        if parsed_path == "/api/stats":
            with ALERTS_LOCK:
                stats = {
                    "critical": sum(1 for a in ALERTS_BUFFER if a.get("rule", {}).get("threat_level") == "CRITICAL"),
                    "high": sum(1 for a in ALERTS_BUFFER if a.get("rule", {}).get("threat_level") == "HIGH"),
                    "medium": sum(1 for a in ALERTS_BUFFER if a.get("rule", {}).get("threat_level") == "MEDIUM"),
                    "low": sum(1 for a in ALERTS_BUFFER if a.get("rule", {}).get("threat_level") == "LOW"),
                    "total": len(ALERTS_BUFFER),
                }
            self._send_json(200, stats)
            return

        self.send_error(404, "Path not found")

    def do_POST(self):
        """Handle incoming event ingestion from audit shipper."""
        parsed_path = self.path.split("?")[0]

        if parsed_path == "/api/events":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            try:
                event_data = json.loads(body)
                if not isinstance(event_data, dict):
                    self._send_json(400, {"error": "Expected JSON object"})
                    return

                # Enrich with ingestion metadata
                if "timestamp" not in event_data:
                    event_data["timestamp"] = datetime.now(timezone.utc).isoformat()

                with ALERTS_LOCK:
                    ALERTS_BUFFER.append(event_data)
                    if len(ALERTS_BUFFER) > MAX_ALERTS:
                        ALERTS_BUFFER.pop(0)

                self._send_json(201, {
                    "status": "accepted",
                    "event_id": event_data.get("audit_event_id"),
                    "rule": event_data.get("rule", {}).get("name"),
                })
            except Exception as err:
                self._send_json(400, {"error": f"Invalid payload: {err}"})
            return

        self.send_error(404, "Path not found")

    def do_DELETE(self):
        """Clear alerts buffer for fresh testing."""
        if self.path.split("?")[0] == "/api/events":
            with ALERTS_LOCK:
                count = len(ALERTS_BUFFER)
                ALERTS_BUFFER.clear()
            self._send_json(200, {"status": "cleared", "deleted_events": count})
            return
        self.send_error(404, "Path not found")

    def log_message(self, format, *args):
        """Suppress standard access logs unless in debug mode."""
        if os.environ.get("SIEM_DEBUG") == "1":
            super().log_message(format, *args)


def run_server(port: int = PORT):
    """Start the multi-threaded SIEM HTTP server."""
    class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server_address = ("0.0.0.0", port)
    httpd = ThreadingHTTPServer(server_address, SIEMRequestHandler)
    print(f"🛡️  SIEM Security Dashboard & API listening on http://0.0.0.0:{port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping SIEM server...")
        httpd.server_close()


if __name__ == "__main__":
    port_arg = int(sys.argv[1]) if len(sys.argv) > 1 else PORT
    run_server(port_arg)
