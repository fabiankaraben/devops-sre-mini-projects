#!/usr/bin/env python3
"""
global_router.py - Global Traffic Router & DNS Failover Controller
===================================================================
Simulates an Anycast DNS / Global Load Balancer (e.g. Route 53 ARC / Cloudflare):
1. Routes incoming customer traffic to the Active Availability Zone.
2. Performs sub-second active health checks against primary and secondary backends.
3. Automatically or deterministically orchestrates DNS switchover upon disaster.
4. Records failover timestamps and latency for precise RTO calculation.
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
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(threadName)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("global_router")


class RouterState:
    """Manages active routing destination, failover history, and health probes."""

    def __init__(self, primary_url: str, secondary_url: str, auto_failover: bool = True):
        self.primary_url = primary_url.rstrip("/")
        self.secondary_url = secondary_url.rstrip("/")
        self.active_target = "PRIMARY"  # PRIMARY or SECONDARY
        self.auto_failover = auto_failover
        self.primary_healthy = True
        self.secondary_healthy = True
        self.primary_consecutive_failures = 0
        self.failover_events: List[Dict[str, Any]] = []
        self.total_routed_requests = 0
        self.lock = threading.RLock()

    def get_active_url(self) -> str:
        with self.lock:
            return self.primary_url if self.active_target == "PRIMARY" else self.secondary_url

    def trigger_failover(self, reason: str = "Manual Orchestration") -> Dict[str, Any]:
        """Switches traffic from PRIMARY to SECONDARY."""
        with self.lock:
            prev = self.active_target
            self.active_target = "SECONDARY"
            event = {
                "event_type": "DNS_FAILOVER_TO_SECONDARY",
                "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "epoch_time": time.time(),
                "reason": reason,
                "previous_target": prev,
                "new_target": self.active_target,
                "new_url": self.secondary_url,
            }
            self.failover_events.append(event)
            logger.critical(f"🔄 [DNS_FAILOVER] Global Router switched traffic to SECONDARY ({self.secondary_url})! Reason: {reason}")
            return event

    def trigger_failback(self, reason: str = "Recovery Complete") -> Dict[str, Any]:
        """Switches traffic back from SECONDARY to PRIMARY."""
        with self.lock:
            prev = self.active_target
            self.active_target = "PRIMARY"
            event = {
                "event_type": "DNS_FAILBACK_TO_PRIMARY",
                "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "epoch_time": time.time(),
                "reason": reason,
                "previous_target": prev,
                "new_target": self.active_target,
                "new_url": self.primary_url,
            }
            self.failover_events.append(event)
            logger.info(f"🔙 [DNS_FAILBACK] Global Router restored traffic to PRIMARY ({self.primary_url}). Reason: {reason}")
            return event

    def update_health(self, target: str, is_healthy: bool) -> None:
        with self.lock:
            if target == "PRIMARY":
                self.primary_healthy = is_healthy
                if not is_healthy:
                    self.primary_consecutive_failures += 1
                    if self.auto_failover and self.active_target == "PRIMARY" and self.primary_consecutive_failures >= 2:
                        self.trigger_failover(reason=f"Primary health check failed ({self.primary_consecutive_failures}x consecutive)")
                else:
                    self.primary_consecutive_failures = 0
            elif target == "SECONDARY":
                self.secondary_healthy = is_healthy


router_state: Optional[RouterState] = None


def health_checker_daemon() -> None:
    """Background thread continuously probing both primary and secondary backends."""
    while True:
        if router_state:
            # Check Primary
            p_ok = probe_backend(router_state.primary_url)
            router_state.update_health("PRIMARY", p_ok)

            # Check Secondary
            s_ok = probe_backend(router_state.secondary_url)
            router_state.update_health("SECONDARY", s_ok)

        time.sleep(0.5)


def probe_backend(url: str) -> bool:
    try:
        req = urllib.request.Request(f"{url}/healthz", headers={"User-Agent": "GlobalRouter-Health/1.0"})
        with urllib.request.urlopen(req, timeout=0.8) as resp:
            return resp.status == 200
    except Exception:
        return False


class RouterHTTPHandler(http.server.BaseHTTPRequestHandler):
    """Reverse Proxy & DNS Gateway Handler."""

    protocol_version = "HTTP/1.1"

    def _send_json(self, status_code: int, data: Dict[str, Any]) -> None:
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if router_state:
            self.send_header("X-Router-Active-Target", router_state.active_target)
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
        if not router_state:
            self._send_json(500, {"error": "Router state uninitialized"})
            return

        path = self.path.split("?")[0]

        # Status & Telemetry
        if path in ("/status", "/router/status"):
            with router_state.lock:
                self._send_json(200, {
                    "service": "global-traffic-router",
                    "active_target": router_state.active_target,
                    "active_url": router_state.get_active_url(),
                    "primary": {"url": router_state.primary_url, "healthy": router_state.primary_healthy},
                    "secondary": {"url": router_state.secondary_url, "healthy": router_state.secondary_healthy},
                    "total_routed": router_state.total_routed_requests,
                    "failover_event_count": len(router_state.failover_events),
                    "failover_events": router_state.failover_events,
                })
            return

        # Forward request to active backend
        self._proxy_request("GET")

    def do_POST(self) -> None:
        if not router_state:
            self._send_json(500, {"error": "Router state uninitialized"})
            return

        path = self.path.split("?")[0]

        if path in ("/failover", "/router/failover"):
            data = self._read_json_body()
            reason = data.get("reason", "API Request")
            ev = router_state.trigger_failover(reason)
            self._send_json(200, ev)
            return

        if path in ("/failback", "/router/failback"):
            data = self._read_json_body()
            reason = data.get("reason", "API Request")
            ev = router_state.trigger_failback(reason)
            self._send_json(200, ev)
            return

        # Forward request to active backend
        self._proxy_request("POST")

    def _proxy_request(self, method: str) -> None:
        active_url = router_state.get_active_url()
        target_endpoint = f"{active_url}{self.path}"
        body_bytes = None

        if method == "POST":
            content_len = int(self.headers.get("Content-Length", 0))
            if content_len > 0:
                body_bytes = self.rfile.read(content_len)

        try:
            req = urllib.request.Request(
                target_endpoint,
                data=body_bytes,
                headers={"Content-Type": "application/json", "User-Agent": "GlobalRouter/1.0"},
                method=method,
            )
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                data = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("X-Router-Active-Target", router_state.active_target)
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(data)
                self.wfile.flush()

                with router_state.lock:
                    router_state.total_routed_requests += 1

        except urllib.error.HTTPError as e:
            err_data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err_data)))
            self.send_header("X-Router-Active-Target", router_state.active_target)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(err_data)
            self.wfile.flush()

        except Exception as e:
            self._send_json(502, {
                "error": "Bad Gateway: Active upstream in AZ is unreachable",
                "active_target": router_state.active_target,
                "active_url": active_url,
                "details": str(e),
            })

    def log_message(self, format: str, *args: Any) -> None:
        pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    global router_state

    parser = argparse.ArgumentParser(description="Global Traffic Router & DNS Failover Controller")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8080)))
    parser.add_argument("--primary-url", type=str, default=os.environ.get("PRIMARY_URL", "http://127.0.0.1:8081"))
    parser.add_argument("--secondary-url", type=str, default=os.environ.get("SECONDARY_URL", "http://127.0.0.1:8082"))
    parser.add_argument("--no-auto-failover", action="store_true", help="Disable automatic health-check based failover")

    args = parser.parse_args()

    router_state = RouterState(
        primary_url=args.primary_url,
        secondary_url=args.secondary_url,
        auto_failover=(not args.no_auto_failover),
    )

    # Launch background health checker daemon
    threading.Thread(target=health_checker_daemon, daemon=True).start()

    server = ThreadedHTTPServer(("0.0.0.0", args.port), RouterHTTPHandler)
    logger.info(
        f"🌍 Global Traffic Router listening on 0.0.0.0:{args.port} | "
        f"Primary Target: {args.primary_url} | Secondary Target: {args.secondary_url} | "
        f"Auto Failover: {not args.no_auto_failover}"
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
