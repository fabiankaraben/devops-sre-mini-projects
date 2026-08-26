#!/usr/bin/env python3
"""
Global Edge Traffic Router & Multi-Region Load Balancer
======================================================
Atomic traffic switcher supporting zero-downtime Blue-Green deployments across
multiple regions (us-east and eu-west).
"""

import os
import sys
import json
import time
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
import itertools

PORT = int(os.environ.get("PORT", "8090"))
HOST = os.environ.get("HOST", "0.0.0.0")
STATE_FILE = os.environ.get("STATE_FILE", "/tmp/router_state.json")

# Default Routing Configuration
DEFAULT_CONFIG = {
    "global_active_color": "blue",
    "regions": {
        "us-east": {
            "active_color": "blue",
            "upstreams": {
                "blue": os.environ.get("UPSTREAM_US_EAST_BLUE", "http://app-us-east-blue:3000"),
                "green": os.environ.get("UPSTREAM_US_EAST_GREEN", "http://app-us-east-green:3000")
            }
        },
        "eu-west": {
            "active_color": "blue",
            "upstreams": {
                "blue": os.environ.get("UPSTREAM_EU_WEST_BLUE", "http://app-eu-west-blue:3000"),
                "green": os.environ.get("UPSTREAM_EU_WEST_GREEN", "http://app-eu-west-green:3000")
            }
        }
    },
    "stats": {
        "total_requests": 0,
        "blue_requests": 0,
        "green_requests": 0,
        "us_east_requests": 0,
        "eu_west_requests": 0
    }
}

ROUTING_STATE = DEFAULT_CONFIG.copy()
REGION_CYCLE = itertools.cycle(["us-east", "eu-west"])

def save_state():
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(ROUTING_STATE, f, indent=2)
    except Exception as e:
        print(f"[WARN] Failed to write state: {e}")

class EdgeProxyHandler(BaseHTTPRequestHandler):
    """Handles global edge proxying and administrative atomic routing switches."""

    def log_message(self, format, *args):
        # Concise logging
        pass

    def send_json(self, status: int, data: dict):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # 1. Health Probe
        if self.path in ["/health", "/livez"]:
            return self.send_json(200, {
                "status": "UP",
                "service": "global-edge-router",
                "active_color": ROUTING_STATE["global_active_color"],
                "regions": list(ROUTING_STATE["regions"].keys()),
                "total_routed": ROUTING_STATE["stats"]["total_requests"]
            })

        # 2. Administrative Status Endpoint
        if self.path == "/admin/status":
            return self.send_json(200, ROUTING_STATE)

        # 3. Private Smoke Test Endpoints (Direct target access)
        # Format: /private/<region>/<color>/<path...>
        if self.path.startswith("/private/"):
            parts = self.path.split("/", 4)
            if len(parts) >= 4:
                target_region = parts[2]
                target_color = parts[3]
                sub_path = "/" + parts[4] if len(parts) > 4 else "/"

                region_cfg = ROUTING_STATE["regions"].get(target_region)
                if region_cfg and target_color in region_cfg["upstreams"]:
                    target_url = region_cfg["upstreams"][target_color] + sub_path
                    return self.forward_request(target_url, target_color, target_region, is_private=True)
            return self.send_json(404, {"error": "Invalid private target path"})

        # 4. Live Multi-Region Traffic Balancing
        # Next region in round-robin sequence
        selected_region = next(REGION_CYCLE)
        active_color = ROUTING_STATE["regions"][selected_region]["active_color"]
        target_base = ROUTING_STATE["regions"][selected_region]["upstreams"][active_color]
        target_url = target_base + self.path

        self.forward_request(target_url, active_color, selected_region)

    def do_POST(self):
        # Dynamic Atomic Routing Pointer Switch
        if self.path == "/admin/route":
            try:
                length = int(self.headers.get("Content-Length", 0))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                new_color = payload.get("active_color", "").lower()
                target_region = payload.get("region", "all").lower()

                if new_color not in ["blue", "green"]:
                    return self.send_json(400, {"error": "active_color must be 'blue' or 'green'"})

                if target_region == "all":
                    ROUTING_STATE["global_active_color"] = new_color
                    for reg in ROUTING_STATE["regions"]:
                        ROUTING_STATE["regions"][reg]["active_color"] = new_color
                elif target_region in ROUTING_STATE["regions"]:
                    ROUTING_STATE["regions"][target_region]["active_color"] = new_color
                else:
                    return self.send_json(400, {"error": f"Unknown region: {target_region}"})

                save_state()
                print(f"[TRAFFIC SWITCH] Active color switched to [{new_color.upper()}] (Region: {target_region})")
                return self.send_json(200, {
                    "status": "SUCCESS",
                    "message": f"Traffic switched to {new_color.upper()}",
                    "active_color": new_color,
                    "target_region": target_region,
                    "timestamp": time.time()
                })
            except Exception as e:
                return self.send_json(500, {"error": f"Failed to update route: {e}"})

        return self.send_json(404, {"error": "Endpoint not found"})

    def forward_request(self, target_url: str, color: str, region: str, is_private: bool = False):
        """Forwards incoming client request to the resolved upstream container."""
        try:
            req = urllib.request.Request(target_url)
            for header, value in self.headers.items():
                if header.lower() not in ["host", "content-length"]:
                    req.add_header(header, value)

            with urllib.request.urlopen(req, timeout=5) as response:
                content = response.read()
                resp_headers = dict(response.info())

                if not is_private:
                    ROUTING_STATE["stats"]["total_requests"] += 1
                    if color == "blue":
                        ROUTING_STATE["stats"]["blue_requests"] += 1
                    else:
                        ROUTING_STATE["stats"]["green_requests"] += 1
                    if region == "us-east":
                        ROUTING_STATE["stats"]["us_east_requests"] += 1
                    else:
                        ROUTING_STATE["stats"]["eu_west_requests"] += 1

                self.send_response(response.status)
                for h, val in resp_headers.items():
                    if h.lower() not in ["transfer-encoding", "content-length"]:
                        self.send_header(h, val)
                self.send_header("X-Routed-Color", color)
                self.send_header("X-Routed-Region", region)
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
        except urllib.error.HTTPError as e:
            content = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Routed-Color", color)
            self.send_header("X-Routed-Region", region)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            err_msg = json.dumps({"error": f"Upstream error ({target_url}): {str(e)}"}).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err_msg)))
            self.end_headers()
            self.wfile.write(err_msg)

def run_server():
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, EdgeProxyHandler)
    print(f"======================================================================")
    print(f"  🚦 Global Edge Traffic Router Online at http://{HOST}:{PORT}")
    print(f"  • Active Color:      [{ROUTING_STATE['global_active_color'].upper()}]")
    print(f"  • Regions Managed:   us-east, eu-west")
    print(f"======================================================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.server_close()

if __name__ == "__main__":
    run_server()
