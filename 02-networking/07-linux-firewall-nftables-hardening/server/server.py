#!/usr/bin/env python3
"""
Hardened Linux Server with Mock Exposed Services & Live nftables Observability API.
"""
import http.server
import json
import os
import socket
import socketserver
import subprocess
import threading
import time
import urllib.parse

PORT_WEB = int(os.getenv("PORT_WEB", "8080"))
PORT_HTTP = int(os.getenv("PORT_HTTP", "80"))
PORT_SSH = int(os.getenv("PORT_SSH", "22"))
START_TIME = time.time()


def get_nft_stats():
    """Retrieve and parse active nftables counters."""
    stats = {
        "cnt_established": {"packets": 0, "bytes": 0},
        "cnt_invalid_drop": {"packets": 0, "bytes": 0},
        "cnt_bad_flags_drop": {"packets": 0, "bytes": 0},
        "cnt_spoofed_drop": {"packets": 0, "bytes": 0},
        "cnt_icmp_flood_drop": {"packets": 0, "bytes": 0},
        "cnt_syn_flood_drop": {"packets": 0, "bytes": 0},
        "cnt_portscan_drop": {"packets": 0, "bytes": 0},
        "cnt_default_drop": {"packets": 0, "bytes": 0},
        "blacklisted_ips": [],
    }

    try:
        res = subprocess.run(
            ["nft", "list", "ruleset"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=2,
        )
        if res.returncode == 0:
            lines = res.stdout.splitlines()
            current_counter = None
            for line in lines:
                line_str = line.strip()
                if line_str.startswith("counter cnt_"):
                    parts = line_str.split()
                    if len(parts) >= 2:
                        current_counter = parts[1]
                elif current_counter and "packets" in line_str and "bytes" in line_str:
                    parts = line_str.split()
                    try:
                        pkts = int(parts[1])
                        bts = int(parts[3])
                        if current_counter in stats:
                            stats[current_counter] = {"packets": pkts, "bytes": bts}
                    except Exception:
                        pass
                    current_counter = None

            # Check dynamic blacklist set
            set_res = subprocess.run(
                ["nft", "list", "set", "inet", "filter", "portscan_blacklist"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=2,
            )
            if set_res.returncode == 0 and "elements =" in set_res.stdout:
                elements_line = [
                    l for l in set_res.stdout.splitlines() if "elements =" in l
                ]
                if elements_line:
                    stats["blacklisted_ips"] = elements_line[0].strip()
    except Exception as e:
        stats["error"] = str(e)

    return stats


def get_nft_ruleset():
    """Retrieve full raw nftables ruleset."""
    try:
        res = subprocess.run(
            ["nft", "list", "ruleset"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=2,
        )
        return res.stdout if res.returncode == 0 else res.stderr
    except Exception as e:
        return f"Error retrieving ruleset: {e}"


class FirewallDashboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
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

        if path in ("/health", "/api/health"):
            self.send_json_response({
                "status": "healthy",
                "uptime_seconds": int(time.time() - START_TIME),
                "firewall": "nftables active",
            })
            return

        if path == "/api/stats":
            self.send_json_response({
                "timestamp": time.time(),
                "uptime_seconds": int(time.time() - START_TIME),
                "stats": get_nft_stats(),
            })
            return

        if path == "/api/ruleset":
            self.send_json_response({
                "ruleset": get_nft_ruleset(),
            })
            return

        if path in ("/", "/index.html"):
            html = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Linux Firewall Hardening with nftables</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-dark: #090d16;
            --card-bg: rgba(22, 30, 49, 0.75);
            --border: rgba(255, 255, 255, 0.1);
            --accent: #38bdf8;
            --accent-glow: rgba(56, 189, 248, 0.3);
            --text: #f8fafc;
            --muted: #94a3b8;
            --danger: #ef4444;
            --success: #10b981;
            --warning: #f59e0b;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Outfit', sans-serif;
            background: radial-gradient(circle at top, #1e1b4b 0%, #090d16 80%);
            color: var(--text);
            min-height: 100vh;
            padding: 2rem 1.5rem;
        }
        .container {
            max-width: 1100px;
            margin: 0 auto;
        }
        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--border);
            padding-bottom: 1.5rem;
            margin-bottom: 2rem;
        }
        .badge {
            background: linear-gradient(135deg, #0284c7, #6366f1);
            padding: 0.4rem 1rem;
            border-radius: 9999px;
            font-weight: 700;
            font-size: 0.85rem;
            letter-spacing: 0.05em;
            text-transform: uppercase;
            box-shadow: 0 0 20px var(--accent-glow);
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
            gap: 1.25rem;
            margin-bottom: 2rem;
        }
        .card {
            background: var(--card-bg);
            backdrop-filter: blur(16px);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 1.5rem;
            box-shadow: 0 10px 25px -5px rgba(0,0,0,0.5);
            transition: transform 0.2s ease, border-color 0.2s ease;
        }
        .card:hover {
            transform: translateY(-2px);
            border-color: rgba(56, 189, 248, 0.4);
        }
        .card-title {
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--muted);
            margin-bottom: 0.5rem;
        }
        .card-value {
            font-family: 'JetBrains Mono', monospace;
            font-size: 1.75rem;
            font-weight: 700;
            color: var(--accent);
        }
        .card-subtitle {
            font-size: 0.8rem;
            color: var(--muted);
            margin-top: 0.35rem;
        }
        .ruleset-container {
            background: #060911;
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 1.5rem;
            margin-top: 2rem;
        }
        pre {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.82rem;
            color: #7dd3fc;
            overflow-x: auto;
            max-height: 380px;
            line-height: 1.5;
            padding-top: 1rem;
        }
        .pulse {
            display: inline-block;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background: var(--success);
            box-shadow: 0 0 10px var(--success);
            margin-right: 6px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1>🛡️ Linux Firewall Hardening (<span style="color: var(--accent);">nftables</span>)</h1>
                <p style="color: var(--muted); margin-top: 0.25rem;">
                    Stateful Netfilter Inspection & Zero-Trust Ingress Hardening
                </p>
            </div>
            <div style="display: flex; align-items: center; gap: 1rem;">
                <span><span class="pulse"></span>Firewall Active</span>
                <span class="badge">Default Drop</span>
            </div>
        </div>

        <div class="grid">
            <div class="card">
                <div class="card-title">Established Connections</div>
                <div id="cnt_established" class="card-value" style="color: var(--success);">0</div>
                <div class="card-subtitle">Legitimate stateful traffic</div>
            </div>
            <div class="card">
                <div class="card-title">SYN Flood Drops</div>
                <div id="cnt_syn_flood_drop" class="card-value" style="color: var(--danger);">0</div>
                <div class="card-subtitle">Ingress rate limit trigger</div>
            </div>
            <div class="card">
                <div class="card-title">ICMP Flood Drops</div>
                <div id="cnt_icmp_flood_drop" class="card-value" style="color: var(--warning);">0</div>
                <div class="card-subtitle">Echo request > 5 req/s</div>
            </div>
            <div class="card">
                <div class="card-title">Bad TCP Flags Drops</div>
                <div id="cnt_bad_flags_drop" class="card-value" style="color: var(--danger);">0</div>
                <div class="card-subtitle">Null, Xmas, SYN-FIN scans</div>
            </div>
            <div class="card">
                <div class="card-title">Invalid State Drops</div>
                <div id="cnt_invalid_drop" class="card-value" style="color: var(--muted);">0</div>
                <div class="card-subtitle">Desynchronized / Corrupt</div>
            </div>
            <div class="card">
                <div class="card-title">Portscan Trap Drops</div>
                <div id="cnt_portscan_drop" class="card-value" style="color: #c084fc;">0</div>
                <div class="card-subtitle">Honeypot dynamic blacklist</div>
            </div>
            <div class="card">
                <div class="card-title">Default Drop Filter</div>
                <div id="cnt_default_drop" class="card-value" style="color: var(--accent);">0</div>
                <div class="card-subtitle">Closed / Unsolicited ports</div>
            </div>
        </div>

        <div class="ruleset-container">
            <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 0.75rem;">
                <h3>Active nftables Ruleset (/etc/nftables.conf)</h3>
                <button onclick="refreshStats()" style="background: var(--accent); color: #000; border: none; padding: 0.4rem 1rem; border-radius: 6px; font-weight: 700; cursor: pointer;">Refresh Counters</button>
            </div>
            <pre id="rulesetOutput">Loading ruleset...</pre>
        </div>
    </div>

    <script>
        async function refreshStats() {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                const s = data.stats;
                for (const k in s) {
                    const el = document.getElementById(k);
                    if (el && s[k].packets !== undefined) {
                        el.innerText = s[k].packets.toLocaleString();
                    }
                }
            } catch (e) {
                console.error(e);
            }
        }

        async function loadRuleset() {
            try {
                const res = await fetch('/api/ruleset');
                const data = await res.json();
                document.getElementById('rulesetOutput').innerText = data.ruleset;
            } catch (e) {
                document.getElementById('rulesetOutput').innerText = 'Error loading ruleset: ' + e;
            }
        }

        refreshStats();
        loadRuleset();
        setInterval(refreshStats, 2000);
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


class HTTPResponder(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        body = b"HTTP/1.1 200 OK - Hardened Linux Production HTTP Service\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run_mock_ssh():
    """Run a mock SSH server banner responder on port 22."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", PORT_SSH))
        s.listen(10)
        print(f"[*] Mock SSH Server listening on port {PORT_SSH}")
        while True:
            conn, addr = s.accept()
            try:
                conn.sendall(b"SSH-2.0-OpenSSH_9.6p1 Debian-4\r\n")
                time.sleep(0.1)
            except Exception:
                pass
            finally:
                conn.close()
    except Exception as e:
        print(f"[-] Could not bind SSH port {PORT_SSH}: {e}")


def run_http_service():
    """Run production HTTP service on port 80."""
    try:
        httpd = socketserver.TCPServer(("0.0.0.0", PORT_HTTP), HTTPResponder)
        print(f"[*] Production HTTP Server listening on port {PORT_HTTP}")
        httpd.serve_forever()
    except Exception as e:
        print(f"[-] Could not bind HTTP port {PORT_HTTP}: {e}")


def run_dashboard_service():
    """Run Web Dashboard & API on port 8080."""
    httpd = socketserver.ThreadingTCPServer(("0.0.0.0", PORT_WEB), FirewallDashboardHandler)
    print(f"[*] Firewall Dashboard & API listening on port {PORT_WEB}")
    httpd.serve_forever()


if __name__ == "__main__":
    t_ssh = threading.Thread(target=run_mock_ssh, daemon=True)
    t_ssh.start()

    t_http = threading.Thread(target=run_http_service, daemon=True)
    t_http.start()

    run_dashboard_service()
