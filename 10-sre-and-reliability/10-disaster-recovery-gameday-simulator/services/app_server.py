#!/usr/bin/env python3
"""
app_server.py - Transactional Microservice for Disaster Recovery Demo
======================================================================
Stateless application server deployed across AZ-A and AZ-B:
1. Exposes /orders transactional API forwarding writes to active DB.
2. Reports Availability Zone in response headers (X-Availability-Zone).
3. Supports runtime reconfiguration (/reconfigure) during DR failover drills.
"""

import argparse
import http.server
import json
import logging
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(threadName)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("app_server")


class AppConfig:
    def __init__(self, app_name: str, az: str, db_url: str):
        self.app_name = app_name
        self.az = az
        self.db_url = db_url.rstrip("/")
        self.total_served = 0
        self.total_failed = 0
        self.lock = threading.Lock()

    def set_db_url(self, new_url: str) -> None:
        with self.lock:
            old = self.db_url
            self.db_url = new_url.rstrip("/")
            logger.info(f"🔄 [RECONFIGURE] DB URL switched from {old} to {self.db_url}")


app_config: Optional[AppConfig] = None


class AppHTTPHandler(http.server.BaseHTTPRequestHandler):
    """Transactional HTTP API Handler."""

    protocol_version = "HTTP/1.1"

    def _send_json(self, status_code: int, data: Dict[str, Any]) -> None:
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if app_config:
            self.send_header("X-Availability-Zone", app_config.az)
            self.send_header("X-App-Server", app_config.app_name)
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(payload)
            self.wfile.flush()
        except Exception:
            pass

    def _read_json_body(self) -> Dict[str, Any]:
        content_len = int(self.headers.get("Content-Length", 0))
        if content_len == 0:
            return {}
        body = self.rfile.read(content_len).decode("utf-8")
        return json.loads(body)

    def do_GET(self) -> None:
        if not app_config:
            self._send_json(500, {"error": "Uninitialized app"})
            return

        path = self.path.split("?")[0]

        # 1. Health Probe
        if path in ("/healthz", "/health"):
            db_healthy, db_info = self._check_db_health()
            code = 200 if db_healthy else 503
            self._send_json(code, {
                "status": "HEALTHY" if db_healthy else "DEGRADED",
                "app_name": app_config.app_name,
                "az": app_config.az,
                "db_target": app_config.db_url,
                "db_health": db_info,
            })
            return

        # 2. Status & Telemetry
        if path == "/status":
            self._send_json(200, {
                "service": "app-server",
                "app_name": app_config.app_name,
                "az": app_config.az,
                "db_target": app_config.db_url,
                "total_served": app_config.total_served,
                "total_failed": app_config.total_failed,
            })
            return

        # 3. Read Order
        if path.startswith("/orders/"):
            order_id = path[len("/orders/"):]
            self._fetch_order(order_id)
            return

        self._send_json(200, {
            "message": "Disaster Recovery App Server",
            "app_name": app_config.app_name,
            "az": app_config.az,
            "endpoints": ["/healthz", "/orders", "/status"],
        })

    def do_POST(self) -> None:
        if not app_config:
            self._send_json(500, {"error": "Uninitialized app"})
            return

        path = self.path.split("?")[0]

        if path == "/reconfigure":
            data = self._read_json_body()
            new_db = data.get("db_url")
            if new_db:
                app_config.set_db_url(new_db)
                self._send_json(200, {"status": "RECONFIGURED", "db_url": app_config.db_url})
            else:
                self._send_json(400, {"error": "Missing db_url parameter"})
            return

        if path in ("/orders", "/api/v1/orders"):
            data = self._read_json_body()
            self._create_order(data)
            return

        self._send_json(404, {"error": f"Endpoint not found: {path}"})

    def _check_db_health(self) -> Tuple[bool, Dict[str, Any]]:
        target = f"{app_config.db_url}/health"
        try:
            req = urllib.request.Request(target, headers={"User-Agent": "AppServer-Health/1.0"})
            with urllib.request.urlopen(req, timeout=1.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return (resp.status == 200), data
        except Exception as e:
            return False, {"error": str(e), "target": target}

    def _create_order(self, order_data: Dict[str, Any]) -> None:
        target = f"{app_config.db_url}/api/tx"
        try:
            payload_bytes = json.dumps(order_data).encode("utf-8")
            req = urllib.request.Request(
                target,
                data=payload_bytes,
                headers={"Content-Type": "application/json", "User-Agent": "AppServer/1.0"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                resp_data = json.loads(resp.read().decode("utf-8"))
                with app_config.lock:
                    app_config.total_served += 1
                self._send_json(resp.status, {
                    "status": "ORDER_CREATED",
                    "az": app_config.az,
                    "app_server": app_config.app_name,
                    "db_response": resp_data,
                })
        except urllib.error.HTTPError as e:
            with app_config.lock:
                app_config.total_failed += 1
            err_body = e.read().decode("utf-8", errors="ignore")
            self._send_json(e.code, {
                "error": f"Database HTTP {e.code}",
                "az": app_config.az,
                "db_details": err_body,
            })
        except Exception as e:
            with app_config.lock:
                app_config.total_failed += 1
            self._send_json(503, {
                "error": "Database Unavailable in AZ",
                "az": app_config.az,
                "details": str(e),
            })

    def _fetch_order(self, order_id: str) -> None:
        target = f"{app_config.db_url}/api/tx/{order_id}"
        try:
            req = urllib.request.Request(target, headers={"User-Agent": "AppServer/1.0"})
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                resp_data = json.loads(resp.read().decode("utf-8"))
                self._send_json(resp.status, resp_data)
        except urllib.error.HTTPError as e:
            self._send_json(e.code, {"error": "Order not found or DB error"})
        except Exception as e:
            self._send_json(503, {"error": "Database Unavailable", "details": str(e)})

    def log_message(self, format: str, *args: Any) -> None:
        pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    global app_config

    parser = argparse.ArgumentParser(description="Disaster Recovery App Server")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8081)))
    parser.add_argument("--app-name", type=str, default=os.environ.get("APP_NAME", "app-primary"))
    parser.add_argument("--az", type=str, default=os.environ.get("AZ", "us-east-1a"))
    parser.add_argument("--db-url", type=str, default=os.environ.get("DB_URL", "http://127.0.0.1:9001"))

    args = parser.parse_args()

    app_config = AppConfig(
        app_name=args.app_name,
        az=args.az,
        db_url=args.db_url,
    )

    server = ThreadedHTTPServer(("0.0.0.0", args.port), AppHTTPHandler)
    logger.info(
        f"🚀 App Server '{args.app_name}' listening on 0.0.0.0:{args.port} | "
        f"AZ: {args.az} | DB Target: {args.db_url}"
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
