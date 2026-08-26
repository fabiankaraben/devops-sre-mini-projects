#!/usr/bin/env python3
"""
Lightweight REST API & Dashboard for Site-to-Site VPN Demo Service.
"""
import http.server
import json
import os
import socket
import subprocess
import time
import urllib.parse
import urllib.request

SITE_NAME = os.getenv("SITE_NAME", "Unknown Site")
SITE_COLOR = os.getenv("SITE_COLOR", "#3b82f6")
GATEWAY_IP = os.getenv("GATEWAY_IP", "10.0.0.1")
PORT = int(os.getenv("PORT", "8080"))
START_TIME = time.time()


def get_local_ip():
    """Retrieve primary IPv4 address of the container."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


class VPNAppHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Concise logging format
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} - {format % args}")

    def send_json_response(self, data, status_code=200):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/health" or path == "/api/health":
            self.send_json_response({
                "status": "healthy",
                "site": SITE_NAME,
                "uptime_seconds": int(time.time() - START_TIME)
            })
            return

        if path == "/api/info":
            self.send_json_response({
                "site_name": SITE_NAME,
                "hostname": socket.gethostname(),
                "local_ip": get_local_ip(),
                "gateway_ip": GATEWAY_IP,
                "timestamp": time.time(),
                "uptime_seconds": int(time.time() - START_TIME)
            })
            return

        if path == "/api/ping":
            target = query.get("target", [""])[0]
            if not target:
                self.send_json_response({"error": "Missing 'target' parameter"}, 400)
                return

            try:
                cmd = ["ping", "-c", "2", "-W", "2", target]
                res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
                success = (res.returncode == 0)
                self.send_json_response({
                    "target": target,
                    "success": success,
                    "output": res.stdout,
                    "returncode": res.returncode
                }, 200 if success else 502)
            except Exception as e:
                self.send_json_response({"target": target, "success": False, "error": str(e)}, 500)
            return

        if path == "/api/fetch":
            target = query.get("target", [""])[0]
            if not target:
                self.send_json_response({"error": "Missing 'target' parameter"}, 400)
                return

            try:
                req = urllib.request.Request(target, headers={"User-Agent": f"VPN-App/{SITE_NAME}"})
                with urllib.request.urlopen(req, timeout=4) as response:
                    raw = response.read().decode("utf-8")
                    try:
                        content = json.loads(raw)
                    except Exception:
                        content = raw
                    self.send_json_response({
                        "target": target,
                        "status_code": response.status,
                        "response": content
                    })
            except Exception as e:
                self.send_json_response({"target": target, "success": False, "error": str(e)}, 502)
            return

        if path == "/" or path == "/index.html":
            local_ip = get_local_ip()
            hostname = socket.gethostname()
            html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{SITE_NAME} - WireGuard VPN Mesh</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
    <style>
        :root {{
            --site-color: {SITE_COLOR};
            --bg-dark: #0f172a;
            --card-bg: rgba(30, 41, 59, 0.7);
            --border-color: rgba(255, 255, 255, 0.1);
            --text-primary: #f8fafc;
            --text-muted: #94a3b8;
            --success: #10b981;
            --danger: #ef4444;
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{
            font-family: 'Outfit', sans-serif;
            background: linear-gradient(135deg, #0b0f19 0%, #1e1b4b 50%, #0f172a 100%);
            color: var(--text-primary);
            min-height: 100vh;
            padding: 2rem;
            display: flex;
            justify-content: center;
            align-items: center;
        }}
        .container {{
            max-width: 800px;
            width: 100%;
            background: var(--card-bg);
            backdrop-filter: blur(16px);
            border: 1px solid var(--border-color);
            border-radius: 20px;
            padding: 2.5rem;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
        }}
        .header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 1.5rem;
            margin-bottom: 2rem;
        }}
        .badge {{
            display: inline-block;
            background: var(--site-color);
            color: white;
            padding: 0.35rem 1rem;
            border-radius: 9999px;
            font-weight: 700;
            font-size: 0.9rem;
            box-shadow: 0 0 15px var(--site-color);
        }}
        .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1.5rem;
            margin-bottom: 2rem;
        }}
        .stat-card {{
            background: rgba(15, 23, 42, 0.6);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 1.25rem;
        }}
        .stat-title {{
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--text-muted);
            margin-bottom: 0.5rem;
        }}
        .stat-value {{
            font-family: 'JetBrains Mono', monospace;
            font-size: 1.15rem;
            font-weight: 600;
            color: #38bdf8;
        }}
        .interactive {{
            background: rgba(15, 23, 42, 0.6);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 1.5rem;
            margin-top: 1.5rem;
        }}
        .input-group {{
            display: flex;
            gap: 0.5rem;
            margin-top: 1rem;
        }}
        input {{
            flex: 1;
            padding: 0.75rem 1rem;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background: #1e293b;
            color: white;
            font-family: 'JetBrains Mono', monospace;
        }}
        button {{
            background: var(--site-color);
            color: white;
            border: none;
            border-radius: 8px;
            padding: 0.75rem 1.5rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
        }}
        button:hover {{
            filter: brightness(1.2);
            transform: translateY(-1px);
        }}
        pre {{
            margin-top: 1rem;
            padding: 1rem;
            background: #090d16;
            border-radius: 8px;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.85rem;
            color: #a7f3d0;
            overflow-x: auto;
            max-height: 200px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1>{SITE_NAME} Internal Service</h1>
                <p style="color: var(--text-muted); margin-top: 0.25rem;">Encrypted WireGuard Mesh Network Node</p>
            </div>
            <span class="badge">{SITE_NAME}</span>
        </div>

        <div class="grid">
            <div class="stat-card">
                <div class="stat-title">Container Hostname</div>
                <div class="stat-value">{hostname}</div>
            </div>
            <div class="stat-card">
                <div class="stat-title">LAN Subnet IP</div>
                <div class="stat-value">{local_ip}</div>
            </div>
            <div class="stat-card">
                <div class="stat-title">Site Gateway Router</div>
                <div class="stat-value">{GATEWAY_IP}</div>
            </div>
        </div>

        <div class="interactive">
            <h3>🧪 Cross-Subnet VPN Connectivity Tester</h3>
            <p style="color: var(--text-muted); font-size: 0.9rem; margin-top: 0.25rem;">
                Test ping or HTTP queries across isolated sites over WireGuard tunnels.
            </p>
            <div class="input-group">
                <input id="targetIp" type="text" value="10.20.0.10" placeholder="e.g. 10.20.0.10 or 10.30.0.10">
                <button onclick="runPing()">ICMP Ping</button>
                <button onclick="fetchApi()" style="background: #6366f1;">HTTP Fetch</button>
            </div>
            <pre id="output">Results will appear here...</pre>
        </div>
    </div>

    <script>
        async function runPing() {{
            const target = document.getElementById('targetIp').value;
            const output = document.getElementById('output');
            output.innerText = 'Pinging ' + target + ' over WireGuard tunnel...';
            try {{
                const res = await fetch('/api/ping?target=' + encodeURIComponent(target));
                const data = await res.json();
                output.innerText = JSON.stringify(data, null, 2);
            }} catch (err) {{
                output.innerText = 'Error: ' + err.message;
            }}
        }}

        async function fetchApi() {{
            const target = document.getElementById('targetIp').value;
            const output = document.getElementById('output');
            const url = 'http://' + target + ':8080/api/info';
            output.innerText = 'Fetching ' + url + ' over WireGuard tunnel...';
            try {{
                const res = await fetch('/api/fetch?target=' + encodeURIComponent(url));
                const data = await res.json();
                output.innerText = JSON.stringify(data, null, 2);
            }} catch (err) {{
                output.innerText = 'Error: ' + err.message;
            }}
        }}
    </script>
</body>
</html>"""
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_json_response({"error": "Not Found", "path": path}, 404)


def run_server():
    server_address = ("0.0.0.0", PORT)
    httpd = http.server.ThreadingHTTPServer(server_address, VPNAppHandler)
    print(f"[*] {SITE_NAME} Web & API server running on port {PORT}")
    print(f"[*] Local IP: {get_local_ip()} | Gateway: {GATEWAY_IP}")
    httpd.serve_forever()


if __name__ == "__main__":
    run_server()
