#!/usr/bin/env python3
"""
Route 53 DNS Failover Gateway & Interactive Dashboard
=====================================================
Emulates Amazon Route 53 Active-Passive DNS Failover Routing.
Continuously runs health checks against Primary (us-east-1) and Secondary (us-west-2),
automatically reroutes traffic upon failure threshold breach, and serves
an interactive real-time visual dashboard.
"""

import json
import logging
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional, Tuple
from urllib.parse import parse_qs, urlparse

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] [%(levelname)s] %(message)s")
logger = logging.getLogger("Route53Gateway")

PRIMARY_URL = os.environ.get("PRIMARY_URL", "http://localhost:8081")
SECONDARY_URL = os.environ.get("SECONDARY_URL", "http://localhost:8082")
HEALTH_CHECK_INTERVAL = float(os.environ.get("HEALTH_CHECK_INTERVAL", "2.0"))
FAILURE_THRESHOLD = int(os.environ.get("FAILURE_THRESHOLD", "3"))
PORT = int(os.environ.get("PORT", "8080"))

# State
ACTIVE_REGION = "us-east-1"
ACTIVE_ROLE = "PRIMARY"
PRIMARY_CONSECUTIVE_FAILURES = 0
SECONDARY_CONSECUTIVE_FAILURES = 0
PRIMARY_HEALTHY = True
SECONDARY_HEALTHY = True
FAILOVER_COUNT = 0
FAILOVER_HISTORY = []
TRAFFIC_LOGS = []
STATE_LOCK = threading.Lock()
START_TIME = time.time()
LAST_FAILOVER_TIME: Optional[float] = None


def probe_health(url: str) -> Tuple[bool, int, float]:
    """Sends HTTP GET to /health and returns (is_healthy, status_code, latency_ms)."""
    t0 = time.time()
    try:
        req = urllib.request.Request(f"{url}/health", headers={"User-Agent": "AmazonRoute53HealthCheck/1.0"})
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            elapsed_ms = (time.time() - t0) * 1000.0
            return resp.getcode() == 200, resp.getcode(), elapsed_ms
    except urllib.error.HTTPError as e:
        elapsed_ms = (time.time() - t0) * 1000.0
        return False, e.code, elapsed_ms
    except Exception:
        elapsed_ms = (time.time() - t0) * 1000.0
        return False, 0, elapsed_ms


def route53_health_checker_daemon():
    """Background daemon polling endpoints and triggering automated failover."""
    global ACTIVE_REGION, ACTIVE_ROLE, PRIMARY_CONSECUTIVE_FAILURES, PRIMARY_HEALTHY
    global SECONDARY_HEALTHY, FAILOVER_COUNT, LAST_FAILOVER_TIME

    logger.info(f"Route 53 Health Checker daemon started (Interval: {HEALTH_CHECK_INTERVAL}s, Threshold: {FAILURE_THRESHOLD})")

    while True:
        p_ok, p_code, p_lat = probe_health(PRIMARY_URL)
        s_ok, s_code, s_lat = probe_health(SECONDARY_URL)

        with STATE_LOCK:
            PRIMARY_HEALTHY = p_ok
            SECONDARY_HEALTHY = s_ok

            if p_ok:
                if PRIMARY_CONSECUTIVE_FAILURES > 0:
                    logger.info(f"Primary (us-east-1) recovered! (HTTP {p_code}, {p_lat:.1f}ms)")
                PRIMARY_CONSECUTIVE_FAILURES = 0

                # Automatic failback to PRIMARY if currently in failover mode
                if ACTIVE_ROLE != "PRIMARY":
                    ACTIVE_REGION = "us-east-1"
                    ACTIVE_ROLE = "PRIMARY"
                    event = {
                        "type": "FAILBACK",
                        "to_region": "us-east-1",
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        "reason": "Primary health check recovered (3 consecutive passing probes)",
                    }
                    FAILOVER_HISTORY.append(event)
                    logger.info(f"🔄 Route 53: Restored DNS routing to PRIMARY (us-east-1)")
            else:
                PRIMARY_CONSECUTIVE_FAILURES += 1
                logger.warning(f"⚠️ Primary health check failed ({PRIMARY_CONSECUTIVE_FAILURES}/{FAILURE_THRESHOLD}) - HTTP {p_code}")

                # Trigger automated failover if threshold breached
                if PRIMARY_CONSECUTIVE_FAILURES >= FAILURE_THRESHOLD and ACTIVE_ROLE != "SECONDARY_DR":
                    ACTIVE_REGION = "us-west-2"
                    ACTIVE_ROLE = "SECONDARY_DR"
                    FAILOVER_COUNT += 1
                    LAST_FAILOVER_TIME = time.time()
                    event = {
                        "type": "FAILOVER",
                        "to_region": "us-west-2",
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        "reason": f"Primary endpoint tripped failure threshold ({FAILURE_THRESHOLD} consecutive failures)",
                    }
                    FAILOVER_HISTORY.append(event)
                    logger.critical(f"🚨 Route 53 DNS FAILOVER TRIGGERED! Rerouted 100% traffic to SECONDARY_DR (us-west-2)")

        time.sleep(HEALTH_CHECK_INTERVAL)


class FailoverGatewayHandler(BaseHTTPRequestHandler):
    """Reverse proxy and Web Dashboard for Route 53 Failover."""

    server_version = "Route53FailoverGateway/1.0"

    def log_message(self, format, *args):
        # Keep gateway console clean
        pass

    def _send_json(self, status_code: int, data: dict):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, status_code: int, html: str):
        payload = html.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _proxy_request(self, target_url: str, method: str):
        """Forward client request to the currently active regional target."""
        parsed = urlparse(self.path)
        path = parsed.path
        if parsed.query:
            path += f"?{parsed.query}"

        full_url = f"{target_url}{path}"
        content_length = int(self.headers.get("Content-Length", 0))
        req_body = self.rfile.read(content_length) if content_length > 0 else None

        req = urllib.request.Request(full_url, data=req_body, method=method)
        for h, val in self.headers.items():
            if h.lower() not in ("host", "content-length"):
                req.add_header(h, val)

        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                body = resp.read()
                elapsed_ms = (time.time() - t0) * 1000.0

                with STATE_LOCK:
                    TRAFFIC_LOGS.append(
                        {
                            "time": datetime.now(timezone.utc).strftime("%H:%M:%S"),
                            "method": method,
                            "path": path,
                            "routed_to": ACTIVE_REGION,
                            "role": ACTIVE_ROLE,
                            "status": resp.getcode(),
                            "latency_ms": round(elapsed_ms, 1),
                        }
                    )
                    if len(TRAFFIC_LOGS) > 20:
                        TRAFFIC_LOGS.pop(0)

                self.send_response(resp.getcode())
                for h, val in resp.getheaders():
                    if h.lower() not in ("transfer-encoding", "content-length"):
                        self.send_header(h, val)
                self.send_header("X-Route53-Routed-To", ACTIVE_REGION)
                self.send_header("X-Route53-Policy", f"FAILOVER_{ACTIVE_ROLE}")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Route53-Routed-To", ACTIVE_REGION)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            err_payload = json.dumps({"error": f"Gateway proxy error: {str(e)}", "active_region": ACTIVE_REGION}).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err_payload)))
            self.end_headers()
            self.wfile.write(err_payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        # 1. Gateway Health Probe
        if path == "/gateway/health":
            with STATE_LOCK:
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "status": "HEALTHY",
                        "active_region": ACTIVE_REGION,
                        "active_role": ACTIVE_ROLE,
                        "primary_healthy": PRIMARY_HEALTHY,
                        "secondary_healthy": SECONDARY_HEALTHY,
                        "primary_failures": PRIMARY_CONSECUTIVE_FAILURES,
                        "failover_count": FAILOVER_COUNT,
                    },
                )
            return

        # 2. Status API for scripts & automation
        if path == "/api/status":
            with STATE_LOCK:
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "active_region": ACTIVE_REGION,
                        "active_role": ACTIVE_ROLE,
                        "primary_region": {"url": PRIMARY_URL, "healthy": PRIMARY_HEALTHY, "failures": PRIMARY_CONSECUTIVE_FAILURES},
                        "secondary_region": {"url": SECONDARY_URL, "healthy": SECONDARY_HEALTHY},
                        "failover_history": FAILOVER_HISTORY,
                    },
                )
            return

        # 3. Interactive Web Dashboard
        if path in ("", "/index.html"):
            with STATE_LOCK:
                reg = ACTIVE_REGION
                role = ACTIVE_ROLE
                p_fail = PRIMARY_CONSECUTIVE_FAILURES
                p_health = PRIMARY_HEALTHY
                s_health = SECONDARY_HEALTHY
                f_count = FAILOVER_COUNT
                logs = list(reversed(TRAFFIC_LOGS))

            p_badge = '<span style="color:#22c55e;">🟢 HEALTHY (Passing)</span>' if p_health else f'<span style="color:#ef4444;">🔴 UNHEALTHY ({p_fail}/{FAILURE_THRESHOLD} failures)</span>'
            s_badge = '<span style="color:#22c55e;">🟢 HEALTHY (Standby)</span>' if s_health else '<span style="color:#ef4444;">🔴 UNHEALTHY</span>'
            active_color = "#22c55e" if role == "PRIMARY" else "#a855f7"

            rows = ""
            for l in logs[:10]:
                badge = "badge-pri" if l["role"] == "PRIMARY" else "badge-sec"
                rows += f"""
                <tr>
                    <td>{l['time']}</td>
                    <td><code>{l['method']} {l['path']}</code></td>
                    <td><span class="badge {badge}">{l['routed_to']} ({l['role']})</span></td>
                    <td><strong>{l['status']}</strong></td>
                    <td>{l['latency_ms']} ms</td>
                </tr>"""

            if not rows:
                rows = "<tr><td colspan='5' style='text-align:center;color:#64748b;padding:18px;'>No traffic forwarded yet.</td></tr>"

            html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Route 53 Multi-Region Disaster Recovery Dashboard</title>
    <style>
        :root {{
            --bg: #090d16;
            --card: #131b2e;
            --border: #1e293b;
            --pri: #22c55e;
            --sec: #a855f7;
            --danger: #ef4444;
            --text: #f8fafc;
            --muted: #94a3b8;
        }}
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 24px; }}
        .container {{ max-width: 1100px; margin: 0 auto; }}
        .header {{ display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 18px; margin-bottom: 24px; }}
        h1 {{ margin: 0; font-size: 22px; color: #38bdf8; display: flex; align-items: center; gap: 10px; }}
        .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; margin-bottom: 24px; }}
        .card {{ background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 20px; }}
        .card-active {{ border: 2px solid {active_color}; box-shadow: 0 0 15px rgba(56, 189, 248, 0.15); }}
        .metric-title {{ font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 6px; }}
        .metric-val {{ font-size: 24px; font-weight: 700; }}
        table {{ width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }}
        th, td {{ padding: 12px 16px; text-align: left; border-bottom: 1px solid var(--border); font-size: 13px; }}
        th {{ background: #0b1120; color: var(--muted); font-size: 11px; text-transform: uppercase; }}
        .badge {{ padding: 4px 10px; border-radius: 9999px; font-size: 11px; font-weight: 600; }}
        .badge-pri {{ background: rgba(34, 197, 94, 0.15); color: var(--pri); }}
        .badge-sec {{ background: rgba(168, 85, 247, 0.15); color: var(--sec); }}
        .btn {{ padding: 8px 16px; border-radius: 6px; border: none; font-weight: 600; font-size: 12px; cursor: pointer; }}
        .btn-fail {{ background: var(--danger); color: #fff; }}
        .btn-heal {{ background: var(--pri); color: #fff; }}
        .pulse {{ animation: pulse 1.5s infinite; }}
        @keyframes pulse {{ 0% {{ opacity: 1; }} 50% {{ opacity: 0.4; }} 100% {{ opacity: 1; }} }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🌐 Amazon Route 53 Multi-Region Disaster Recovery</h1>
            <button class="btn" style="background:#38bdf8;color:#0f172a;" onclick="location.reload()">🔄 Refresh</button>
        </div>

        <div class="grid">
            <div class="card card-active">
                <div class="metric-title">Active DNS Route (Failover Policy)</div>
                <div class="metric-val" style="color: {active_color};">{reg} <span style="font-size:14px;color:var(--muted);">({role})</span></div>
            </div>
            <div class="card">
                <div class="metric-title">Primary Region (us-east-1)</div>
                <div class="metric-val" style="font-size: 16px; margin-top: 4px;">{p_badge}</div>
            </div>
            <div class="card">
                <div class="metric-title">Secondary DR Region (us-west-2)</div>
                <div class="metric-val" style="font-size: 16px; margin-top: 4px;">{s_badge}</div>
            </div>
            <div class="card">
                <div class="metric-title">Failovers Triggered</div>
                <div class="metric-val">{f_count}</div>
            </div>
        </div>

        <div class="card" style="margin-bottom: 24px;">
            <h3 style="margin-top:0;font-size:15px;color:#38bdf8;">🧪 Chaos Engineering & Outage Simulator</h3>
            <p style="font-size:13px;color:var(--muted);margin-bottom:14px;">
                Simulate a sudden datacenter failure in <code>us-east-1</code>. Route 53 will detect 3 failed health checks and reroute 100% traffic to <code>us-west-2</code>.
            </p>
            <button class="btn btn-fail" onclick="fetch('{PRIMARY_URL}/chaos/fail', {{method:'POST', mode:'no-cors'}}).then(()=>setTimeout(()=>location.reload(), 500))">💥 Crash Primary (us-east-1)</button>
            <button class="btn btn-heal" onclick="fetch('{PRIMARY_URL}/chaos/restore', {{method:'POST', mode:'no-cors'}}).then(()=>setTimeout(()=>location.reload(), 500))">🛡️ Restore Primary Health</button>
        </div>

        <div class="card" style="padding:0;">
            <table>
                <thead>
                    <tr>
                        <th>Time (UTC)</th>
                        <th>Request</th>
                        <th>Route 53 Target</th>
                        <th>Status</th>
                        <th>Latency</th>
                    </tr>
                </thead>
                <tbody>
                    {rows}
                </tbody>
            </table>
        </div>
    </div>
</body>
</html>"""
            self._send_html(HTTPStatus.OK, html)
            return

        # Forward all other requests (/api/data, /api/info, /health) to currently active region
        with STATE_LOCK:
            target = PRIMARY_URL if ACTIVE_ROLE == "PRIMARY" else SECONDARY_URL
        self._proxy_request(target, "GET")

    def do_POST(self):
        with STATE_LOCK:
            target = PRIMARY_URL if ACTIVE_ROLE == "PRIMARY" else SECONDARY_URL
        self._proxy_request(target, "POST")


def run_gateway(port: int = PORT):
    # Start health checker background daemon
    t = threading.Thread(target=route53_health_checker_daemon, daemon=True)
    t.start()

    server_address = ("", port)
    httpd = ThreadingHTTPServer(server_address, FailoverGatewayHandler)
    print(f"🚀 Route 53 DNS Failover Gateway active on port {port}...")
    print(f"   Primary Target:   {PRIMARY_URL} (us-east-1)")
    print(f"   Secondary Target: {SECONDARY_URL} (us-west-2)")
    sys.stdout.flush()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down Gateway...")
        httpd.server_close()


if __name__ == "__main__":
    port_num = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else PORT
    run_gateway(port=port_num)
