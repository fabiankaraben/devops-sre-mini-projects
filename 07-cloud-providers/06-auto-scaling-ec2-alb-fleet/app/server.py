#!/usr/bin/env python3
"""
High-Availability EC2 Web Application Server
============================================
A lightweight, zero-dependency HTTP server designed for EC2 Launch Templates
and local Docker/ALB testing. Exposes rich instance metadata, ELB health checks,
dynamic CPU stress generator for Auto Scaling scale-out testing, and simulated
failure endpoints for self-healing verification.
"""

import json
import os
import socket
import sys
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Global state
START_TIME = time.time()
REQUEST_COUNT = 0
REQUEST_LOCK = threading.Lock()
IS_HEALTHY = True
HEALTH_LOCK = threading.Lock()
ACTIVE_STRESS_THREADS = 0
STRESS_LOCK = threading.Lock()


def get_health() -> bool:
    """Thread-safe getter for health state."""
    with HEALTH_LOCK:
        return IS_HEALTHY


def set_health(healthy: bool):
    """Thread-safe setter for health state."""
    global IS_HEALTHY
    with HEALTH_LOCK:
        IS_HEALTHY = healthy


def get_ec2_metadata(path: str, timeout: float = 1.0) -> str:
    """Fetch EC2 metadata using IMDSv2."""
    try:
        # Step 1: Request IMDSv2 Session Token
        token_req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
            method="PUT",
        )
        with urllib.request.urlopen(token_req, timeout=timeout) as resp:
            token = resp.read().decode("utf-8")

        # Step 2: Query metadata using token
        meta_req = urllib.request.Request(
            f"http://169.254.169.254/latest/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
        )
        with urllib.request.urlopen(meta_req, timeout=timeout) as resp:
            return resp.read().decode("utf-8").strip()
    except Exception:
        return ""


def discover_instance_info() -> dict:
    """Discover instance metadata from IMDSv2 or fallback to environment/system."""
    instance_id = get_ec2_metadata("instance-id")
    az = get_ec2_metadata("placement/availability-zone")
    local_ip = get_ec2_metadata("local-ipv4")
    ami_id = get_ec2_metadata("ami-id")

    # Fallback to environment variables or socket info (useful in Docker/local testing)
    if not instance_id:
        instance_id = os.environ.get("INSTANCE_ID", f"i-{socket.gethostname()[:8]}")
    if not az:
        az = os.environ.get("AVAILABILITY_ZONE", "us-east-1a")
    if not local_ip:
        try:
            local_ip = socket.gethostbyname(socket.gethostname())
        except Exception:
            local_ip = "127.0.0.1"
    if not ami_id:
        ami_id = os.environ.get("AMI_ID", "ami-simulated-al2023")

    return {
        "instance_id": instance_id,
        "availability_zone": az,
        "region": az[:-1] if len(az) > 1 and az[-1].isalpha() else "us-east-1",
        "local_ipv4": local_ip,
        "ami_id": ami_id,
        "hostname": socket.gethostname(),
        "app_version": "1.0.0",
    }


INSTANCE_INFO = discover_instance_info()


def get_cpu_estimate() -> float:
    """Estimate current CPU load percentage."""
    try:
        load1, _, _ = os.getloadavg()
        cpu_count = os.cpu_count() or 1
        return round(min(100.0, (load1 / cpu_count) * 100.0), 1)
    except Exception:
        return 0.0


def cpu_stress_worker(duration_seconds: int):
    """Worker thread running CPU-intensive arithmetic to trigger scaling."""
    global ACTIVE_STRESS_THREADS
    with STRESS_LOCK:
        ACTIVE_STRESS_THREADS += 1

    end_time = time.time() + duration_seconds
    try:
        # Perform busy math loop
        x = 0
        while time.time() < end_time:
            x = (x + 1) * 314159 % 1000003
    finally:
        with STRESS_LOCK:
            ACTIVE_STRESS_THREADS = max(0, ACTIVE_STRESS_THREADS - 1)


class FleetAppHandler(BaseHTTPRequestHandler):
    """HTTP Request Handler for EC2 fleet nodes."""

    server_version = "EC2FleetWebServer/1.0"

    def log_message(self, format, *args):
        """Custom concise log format."""
        sys.stdout.write(
            f"[{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}] "
            f"{self.address_string()} - {format % args}\n"
        )
        sys.stdout.flush()

    def _increment_request_count(self) -> int:
        global REQUEST_COUNT
        with REQUEST_LOCK:
            REQUEST_COUNT += 1
            return REQUEST_COUNT

    def _send_json(self, status_code: int, data: dict):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Instance-Id", INSTANCE_INFO["instance_id"])
        self.send_header("X-Availability-Zone", INSTANCE_INFO["availability_zone"])
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, status_code: int, html_content: str):
        payload = html_content.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Instance-Id", INSTANCE_INFO["instance_id"])
        self.send_header("X-Availability-Zone", INSTANCE_INFO["availability_zone"])
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        req_num = self._increment_request_count()
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        query_params = parse_qs(parsed.query)

        # ----------------------------------------------------------------------
        # 1. Health Check Endpoint (/health)
        # ----------------------------------------------------------------------
        if path == "/health":
            healthy = get_health()
            uptime = round(time.time() - START_TIME, 1)

            if healthy:
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "status": "healthy",
                        "instance_id": INSTANCE_INFO["instance_id"],
                        "availability_zone": INSTANCE_INFO["availability_zone"],
                        "uptime_seconds": uptime,
                        "request_number": req_num,
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    },
                )
            else:
                self._send_json(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {
                        "status": "unhealthy",
                        "instance_id": INSTANCE_INFO["instance_id"],
                        "availability_zone": INSTANCE_INFO["availability_zone"],
                        "reason": "Simulated instance failure (triggered via /fail endpoint)",
                        "uptime_seconds": uptime,
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    },
                )
            return

        # ----------------------------------------------------------------------
        # 2. Machine-Readable Metadata Endpoint (/api/info)
        # ----------------------------------------------------------------------
        if path == "/api/info":
            uptime = round(time.time() - START_TIME, 1)
            healthy = get_health()
            with STRESS_LOCK:
                stress_workers = ACTIVE_STRESS_THREADS

            self._send_json(
                HTTPStatus.OK,
                {
                    "instance": INSTANCE_INFO,
                    "health": {
                        "status": "healthy" if healthy else "unhealthy",
                        "uptime_seconds": uptime,
                        "total_requests": req_num,
                    },
                    "metrics": {
                        "estimated_cpu_percent": get_cpu_estimate(),
                        "active_stress_workers": stress_workers,
                    },
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                },
            )
            return

        # ----------------------------------------------------------------------
        # 3. CPU Stress Trigger (/stress)
        # ----------------------------------------------------------------------
        if path == "/stress":
            duration = int(query_params.get("duration", ["30"])[0])
            threads_count = int(query_params.get("threads", ["4"])[0])
            duration = max(1, min(duration, 300))  # Bound between 1s and 300s
            threads_count = max(1, min(threads_count, 16))

            for _ in range(threads_count):
                t = threading.Thread(target=cpu_stress_worker, args=(duration,), daemon=True)
                t.start()

            self._send_json(
                HTTPStatus.ACCEPTED,
                {
                    "message": f"Spawned {threads_count} CPU stress threads for {duration} seconds.",
                    "instance_id": INSTANCE_INFO["instance_id"],
                    "availability_zone": INSTANCE_INFO["availability_zone"],
                    "duration_seconds": duration,
                    "threads": threads_count,
                    "action": "Triggering CloudWatch High CPU Alarm / ASG Scale-Out",
                },
            )
            return

        # ----------------------------------------------------------------------
        # 4. Simulated Failure Endpoint (/fail)
        # ----------------------------------------------------------------------
        if path == "/fail":
            set_health(False)
            self._send_json(
                HTTPStatus.OK,
                {
                    "message": "Instance health toggled to UNHEALTHY. Next ELB health checks will fail (HTTP 500).",
                    "instance_id": INSTANCE_INFO["instance_id"],
                    "availability_zone": INSTANCE_INFO["availability_zone"],
                    "status": "unhealthy",
                    "action": "ALB Target Group will mark instance Unhealthy -> ASG Self-Healing Replacement",
                },
            )
            return

        # ----------------------------------------------------------------------
        # 5. Recovery Endpoint (/recover)
        # ----------------------------------------------------------------------
        if path == "/recover":
            set_health(True)
            self._send_json(
                HTTPStatus.OK,
                {
                    "message": "Instance health restored to HEALTHY.",
                    "instance_id": INSTANCE_INFO["instance_id"],
                    "availability_zone": INSTANCE_INFO["availability_zone"],
                    "status": "healthy",
                },
            )
            return

        # ----------------------------------------------------------------------
        # 6. Main Dashboard (/)
        # ----------------------------------------------------------------------
        if path == "" or path == "/index.html":
            # Check if JSON was requested via header or parameter
            accept = self.headers.get("Accept", "")
            if "application/json" in accept or "json" in query_params.get("format", [""])[0]:
                uptime = round(time.time() - START_TIME, 1)
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "message": "Welcome to High-Availability EC2 Fleet behind ALB",
                        "instance_id": INSTANCE_INFO["instance_id"],
                        "availability_zone": INSTANCE_INFO["availability_zone"],
                        "local_ip": INSTANCE_INFO["local_ipv4"],
                        "request_number": req_num,
                        "uptime_seconds": uptime,
                    },
                )
                return

            # Render HTML Dashboard
            uptime_min = round((time.time() - START_TIME) / 60, 2)
            healthy = get_health()
            healthy_status = "HEALTHY" if healthy else "UNHEALTHY"
            status_color = "#10b981" if healthy else "#ef4444"
            with STRESS_LOCK:
                current_stress = ACTIVE_STRESS_THREADS

            html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>EC2 Fleet Auto Scaling Dashboard</title>
    <style>
        :root {{
            --bg-color: #0f172a;
            --card-bg: #1e293b;
            --card-border: #334155;
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --accent-blue: #38bdf8;
            --accent-green: #34d399;
            --accent-amber: #fbbf24;
            --accent-purple: #c084fc;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-primary);
            margin: 0;
            padding: 24px;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            box-sizing: border-box;
        }}
        .container {{
            max-width: 800px;
            width: 100%;
            background: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 16px;
            padding: 32px;
            box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.5), 0 8px 10px -6px rgba(0, 0, 0, 0.4);
        }}
        .header {{
            border-bottom: 1px solid var(--card-border);
            padding-bottom: 20px;
            margin-bottom: 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 12px;
        }}
        h1 {{
            margin: 0;
            font-size: 24px;
            color: var(--accent-blue);
            display: flex;
            align-items: center;
            gap: 10px;
        }}
        .badge {{
            padding: 6px 14px;
            border-radius: 9999px;
            font-weight: 600;
            font-size: 13px;
            letter-spacing: 0.05em;
            text-transform: uppercase;
        }}
        .badge-az {{
            background: rgba(56, 189, 248, 0.15);
            color: var(--accent-blue);
            border: 1px solid rgba(56, 189, 248, 0.3);
        }}
        .badge-status {{
            background: rgba(16, 185, 129, 0.15);
            color: {status_color};
            border: 1px solid {status_color};
        }}
        .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }}
        .metric-card {{
            background: #0f172a;
            border: 1px solid var(--card-border);
            border-radius: 12px;
            padding: 16px;
        }}
        .metric-label {{
            font-size: 12px;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 6px;
        }}
        .metric-value {{
            font-size: 18px;
            font-weight: 700;
            font-family: monospace;
            color: #ffffff;
            word-break: break-all;
        }}
        .actions {{
            border-top: 1px solid var(--card-border);
            padding-top: 24px;
        }}
        .btn-group {{
            display: flex;
            gap: 12px;
            flex-wrap: wrap;
            margin-top: 12px;
        }}
        button {{
            padding: 10px 18px;
            border-radius: 8px;
            font-weight: 600;
            font-size: 14px;
            cursor: pointer;
            border: none;
            transition: all 0.2s ease;
        }}
        .btn-stress {{
            background: #f59e0b;
            color: #000;
        }}
        .btn-stress:hover {{
            background: #d97706;
        }}
        .btn-fail {{
            background: #ef4444;
            color: #fff;
        }}
        .btn-fail:hover {{
            background: #dc2626;
        }}
        .btn-recover {{
            background: #10b981;
            color: #fff;
        }}
        .btn-recover:hover {{
            background: #059669;
        }}
        .btn-refresh {{
            background: #3b82f6;
            color: #fff;
        }}
        .btn-refresh:hover {{
            background: #2563eb;
        }}
        .footer {{
            margin-top: 24px;
            font-size: 12px;
            color: var(--text-secondary);
            text-align: center;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🌐 AWS Auto Scaling Fleet</h1>
            <div>
                <span class="badge badge-az">📍 {INSTANCE_INFO['availability_zone']}</span>
                <span class="badge badge-status">● {healthy_status}</span>
            </div>
        </div>

        <div class="grid">
            <div class="metric-card">
                <div class="metric-label">Instance ID</div>
                <div class="metric-value">{INSTANCE_INFO['instance_id']}</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Private IPv4</div>
                <div class="metric-value">{INSTANCE_INFO['local_ipv4']}</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Availability Zone</div>
                <div class="metric-value">{INSTANCE_INFO['availability_zone']}</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Uptime</div>
                <div class="metric-value">{uptime_min} min</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Requests Handled</div>
                <div class="metric-value">#{req_num}</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Active Stress Threads</div>
                <div class="metric-value" style="color: {'#f59e0b' if current_stress > 0 else '#ffffff'};">{current_stress}</div>
            </div>
        </div>

        <div class="actions">
            <div class="metric-label">🧪 Interactive Chaos & Scaling Controls</div>
            <div class="btn-group">
                <button class="btn-refresh" onclick="location.reload()">🔄 Refresh (Test ALB Balance)</button>
                <button class="btn-stress" onclick="fetch('/stress?duration=30&threads=4').then(r=>r.json()).then(d=>alert(d.message))">🔥 Trigger CPU Stress (30s)</button>
                <button class="btn-fail" onclick="fetch('/fail').then(r=>r.json()).then(d=>alert(d.message))">💥 Simulate Unhealthy (500)</button>
                <button class="btn-recover" onclick="fetch('/recover').then(r=>r.json()).then(d=>alert(d.message))">💚 Restore Health (200)</button>
            </div>
        </div>

        <div class="footer">
            Architecture: Application Load Balancer (ALB) + Auto Scaling Group (Multi-AZ Fleet)
        </div>
    </div>
</body>
</html>
"""
            self._send_html(HTTPStatus.OK, html)
            return

        # Fallback 404
        self._send_json(
            HTTPStatus.NOT_FOUND,
            {
                "error": "Not Found",
                "path": self.path,
                "available_endpoints": ["/", "/health", "/api/info", "/stress", "/fail", "/recover"],
            },
        )

    def do_POST(self):
        # Route POST requests identically to GET for ease of API and curl testing
        self.do_GET()


def run_server(port: int = 80):
    """Run the HTTP server."""
    server_address = ("", port)
    httpd = ThreadingHTTPServer(server_address, FleetAppHandler)
    print(f"🚀 EC2 Fleet Web Server running on port {port}...")
    print(f"   Instance ID:       {INSTANCE_INFO['instance_id']}")
    print(f"   Availability Zone: {INSTANCE_INFO['availability_zone']}")
    print(f"   Private IP:        {INSTANCE_INFO['local_ipv4']}")
    sys.stdout.flush()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down web server...")
        httpd.server_close()


if __name__ == "__main__":
    port_arg = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", "80"))
    run_server(port=port_arg)
