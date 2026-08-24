#!/usr/bin/env python3
"""
==============================================================================
app.py - Payment Microservice with In-Memory Vault Secret Hot-Reloading
==============================================================================
Demonstrates consuming secrets injected by the Vault Agent Sidecar into
in-memory tmpfs (/vault/secrets/config.json and /vault/secrets/app.env)
with zero-downtime hot-reloading.
==============================================================================
"""

import json
import os
import sys
import time
from datetime import datetime
from typing import Dict, Any
from http.server import HTTPServer, BaseHTTPRequestHandler

SECRETS_CONFIG_PATH = os.getenv("SECRETS_CONFIG_PATH", "/vault/secrets/config.json")
SECRETS_ENV_PATH = os.getenv("SECRETS_ENV_PATH", "/vault/secrets/app.env")
PORT = int(os.getenv("PORT", "8080"))

# State Tracking
STATE = {
    "last_mtime": 0.0,
    "reload_count": 0,
    "last_reload_time": "Never",
    "secrets": {},
    "secret_version": "unknown"
}


def load_secrets() -> Dict[str, Any]:
    """Reads secrets from the in-memory shared volume if modified."""
    global STATE
    if os.path.exists(SECRETS_CONFIG_PATH):
        try:
            mtime = os.path.getmtime(SECRETS_CONFIG_PATH)
            if mtime > STATE["last_mtime"]:
                with open(SECRETS_CONFIG_PATH, "r") as f:
                    content = f.read().strip()
                    if content:
                        data = json.loads(content)
                        STATE["secrets"] = data
                        STATE["secret_version"] = str(data.get("secret_version", "1"))
                        STATE["last_mtime"] = mtime
                        STATE["reload_count"] += 1
                        STATE["last_reload_time"] = datetime.utcnow().isoformat() + "Z"
                        print(f"[{datetime.utcnow().isoformat()}] 🔄 [HOT-RELOAD] In-memory secret updated to Version {STATE['secret_version']} (Reload #{STATE['reload_count']})", flush=True)
        except Exception as e:
            print(f"⚠️ Error reading {SECRETS_CONFIG_PATH}: {e}", flush=True)
    return STATE["secrets"]


class PaymentServiceHandler(BaseHTTPRequestHandler):
    """HTTP Handler exposing health and live in-memory secrets."""

    def _set_headers(self, status: int = 200, content_type: str = "application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("X-Service-Name", "payment-service")
        self.end_headers()

    def do_GET(self):
        load_secrets()

        if self.path == "/health":
            self._set_headers(200)
            resp = {
                "status": "UP",
                "secrets_loaded": bool(STATE["secrets"]),
                "secret_version": STATE["secret_version"],
                "reload_count": STATE["reload_count"]
            }
            self.wfile.write(json.dumps(resp, indent=2).encode("utf-8"))

        elif self.path == "/secrets":
            self._set_headers(200)
            secrets = STATE["secrets"]
            masked_stripe = secrets.get("stripe_api_key", "N/A")
            if len(masked_stripe) > 12:
                masked_stripe = masked_stripe[:8] + "..." + masked_stripe[-4:]

            resp = {
                "service": "payment-service",
                "secret_version": STATE["secret_version"],
                "reload_count": STATE["reload_count"],
                "last_reload_time": STATE["last_reload_time"],
                "secrets": {
                    "stripe_api_key_masked": masked_stripe,
                    "stripe_api_key_raw": secrets.get("stripe_api_key", "N/A"),
                    "jwt_secret_preview": (secrets.get("jwt_secret", "N/A")[:10] + "...") if secrets.get("jwt_secret") else "N/A",
                    "database_password": secrets.get("database_password", "N/A"),
                    "rendered_at": secrets.get("rendered_at", "N/A")
                }
            }
            self.wfile.write(json.dumps(resp, indent=2).encode("utf-8"))

        elif self.path == "/metrics":
            self._set_headers(200, "text/plain")
            metrics = (
                f"# HELP payment_service_secret_version Current active secret version\n"
                f"# TYPE payment_service_secret_version gauge\n"
                f"payment_service_secret_version {STATE['secret_version'] if STATE['secret_version'].isdigit() else 1}\n"
                f"# HELP payment_service_secret_reloads_total Total hot-reloads of secrets\n"
                f"# TYPE payment_service_secret_reloads_total counter\n"
                f"payment_service_secret_reloads_total {STATE['reload_count']}\n"
            )
            self.wfile.write(metrics.encode("utf-8"))

        else:
            self._set_headers(404)
            self.wfile.write(b'{"error": "Not Found", "endpoints": ["/health", "/secrets", "/metrics"]}')

    def log_message(self, format, *args):
        """Suppress default access log spam in stdout."""
        pass


def run_server():
    print(f"🚀 Payment Service Microservice starting on port {PORT}...", flush=True)
    print(f"📂 Watching in-memory secret path: {SECRETS_CONFIG_PATH}", flush=True)
    load_secrets()
    server_address = ("", PORT)
    httpd = HTTPServer(server_address, PaymentServiceHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down Payment Service HTTP Server...", flush=True)
        httpd.server_close()


if __name__ == "__main__":
    run_server()
