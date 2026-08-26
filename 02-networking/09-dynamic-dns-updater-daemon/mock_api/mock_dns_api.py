#!/usr/bin/env python3
"""
Mock Cloud DNS & WAN IP Discovery Server (Cloudflare v4 & AWS Route53 Compatible)
Simulates dynamic WAN IP transitions, cloud DNS REST APIs, fault injection (429/500),
and serves the interactive SRE web dashboard.
"""

import json
import os
import random
import re
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", 8080))
WEB_DIR = os.environ.get("WEB_DIR", "/app/web")

# In-memory DNS state and WAN IP state
CURRENT_WAN_IP = os.environ.get("INITIAL_WAN_IP", "203.0.113.10")
DNS_ZONES = {
    "zone_1234567890abcdef": {
        "id": "zone_1234567890abcdef",
        "name": "example.com",
        "records": {
            "rec_home_01": {
                "id": "rec_home_01",
                "zone_id": "zone_1234567890abcdef",
                "name": "home.example.com",
                "type": "A",
                "content": "203.0.113.10",
                "ttl": 120,
                "proxied": False,
                "modified_on": datetime.now(timezone.utc).isoformat()
            },
            "rec_vpn_02": {
                "id": "rec_vpn_02",
                "zone_id": "zone_1234567890abcdef",
                "name": "vpn.example.com",
                "type": "A",
                "content": "203.0.113.10",
                "ttl": 120,
                "proxied": False,
                "modified_on": datetime.now(timezone.utc).isoformat()
            }
        }
    }
}

AUDIT_LOG = []
SIMULATED_FAULT = {
    "enabled": False,
    "status_code": 500,
    "remaining_count": 0,
    "error_message": "Simulated Cloudflare API 500 Internal Server Error"
}

class ThreadingSimpleServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class MockDNSHandler(BaseHTTPRequestHandler):
    server_version = "MockCloudflareAPI/4.0"

    def _send_json(self, status_code, data, extra_headers=None):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Auth-Key, X-Auth-Email")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def _send_text(self, status_code, text):
        payload = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self._send_json(200, {"status": "ok"})

    def _record_audit(self, action, record_name, old_ip, new_ip, status="SUCCESS", note=""):
        entry = {
            "id": f"aud-{int(time.time()*1000)}-{len(AUDIT_LOG)}",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "action": action,
            "record_name": record_name,
            "old_ip": old_ip,
            "new_ip": new_ip,
            "status": status,
            "note": note,
            "client_ip": self.client_address[0]
        }
        AUDIT_LOG.append(entry)
        if len(AUDIT_LOG) > 200:
            AUDIT_LOG.pop(0)

    def do_GET(self):
        global CURRENT_WAN_IP
        path_clean = self.path.split("?")[0]
        query = self.path.split("?")[1] if "?" in self.path else ""

        # ----------------------------------------------------------------------
        # 1. WAN IP Discovery Endpoints
        # ----------------------------------------------------------------------
        if path_clean in ("/ip", "/api/ip", "/v1/ip", "/checkip"):
            self._send_text(200, CURRENT_WAN_IP.strip() + "\n")
            return

        if path_clean == "/json/ip":
            self._send_json(200, {"ip": CURRENT_WAN_IP, "status": "ok"})
            return

        # ----------------------------------------------------------------------
        # 2. Healthcheck
        # ----------------------------------------------------------------------
        if path_clean == "/health":
            self._send_json(200, {
                "status": "healthy",
                "service": "mock-dns-api",
                "current_wan_ip": CURRENT_WAN_IP,
                "zones_count": len(DNS_ZONES)
            })
            return

        # ----------------------------------------------------------------------
        # 3. Cloudflare v4 Zones Endpoint
        # ----------------------------------------------------------------------
        if path_clean == "/client/v4/zones":
            zones_list = [{
                "id": z["id"],
                "name": z["name"],
                "status": "active",
                "paused": False,
                "type": "full"
            } for z in DNS_ZONES.values()]
            self._send_json(200, {
                "success": True,
                "errors": [],
                "messages": [],
                "result": zones_list
            })
            return

        # ----------------------------------------------------------------------
        # 4. Cloudflare v4 DNS Records Query: /client/v4/zones/{zone_id}/dns_records
        # ----------------------------------------------------------------------
        match_dns = re.match(r"^/client/v4/zones/([^/]+)/dns_records(?:/([^/]+))?$", path_clean)
        if match_dns:
            zone_id = match_dns.group(1)
            record_id = match_dns.group(2)
            if zone_id not in DNS_ZONES:
                self._send_json(404, {"success": False, "errors": [{"code": 1000, "message": "Zone not found"}]})
                return

            zone = DNS_ZONES[zone_id]
            if record_id:
                if record_id in zone["records"]:
                    self._send_json(200, {"success": True, "errors": [], "result": zone["records"][record_id]})
                else:
                    self._send_json(404, {"success": False, "errors": [{"code": 81044, "message": "Record not found"}]})
                return

            # Filter by query params (?name=...&type=...)
            filtered = list(zone["records"].values())
            params = dict(p.split("=") for p in query.split("&") if "=" in p)
            if "name" in params:
                filtered = [r for r in filtered if r["name"] == params["name"]]
            if "type" in params:
                filtered = [r for r in filtered if r["type"] == params["type"]]

            self._send_json(200, {
                "success": True,
                "errors": [],
                "messages": [],
                "result": filtered,
                "result_info": {"page": 1, "per_page": 100, "count": len(filtered), "total_count": len(filtered)}
            })
            return

        # ----------------------------------------------------------------------
        # 5. Live Observability Status for Dashboard & Tests
        # ----------------------------------------------------------------------
        if path_clean == "/api/dns/status":
            records_flat = []
            for z in DNS_ZONES.values():
                for r in z["records"].values():
                    records_flat.append(r)

            self._send_json(200, {
                "current_wan_ip": CURRENT_WAN_IP,
                "records": records_flat,
                "fault_simulation": SIMULATED_FAULT,
                "total_audit_events": len(AUDIT_LOG),
                "recent_audit": AUDIT_LOG[-15:]
            })
            return

        if path_clean == "/api/dns/audit":
            self._send_json(200, {"total": len(AUDIT_LOG), "entries": AUDIT_LOG})
            return

        # ----------------------------------------------------------------------
        # 6. Web Dashboard UI File Serving
        # ----------------------------------------------------------------------
        index_path = os.path.join(WEB_DIR, "index.html")
        if os.path.exists(index_path):
            with open(index_path, "r", encoding="utf-8") as f:
                content = f.read()
            payload = content.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self._send_json(404, {"error": "Not Found", "path": self.path})

    def do_POST(self):
        global CURRENT_WAN_IP, SIMULATED_FAULT
        path_clean = self.path.split("?")[0]
        content_len = int(self.headers.get("Content-Length", 0))
        body_raw = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else "{}"
        try:
            body_json = json.loads(body_raw)
        except Exception:
            body_json = {}

        # ----------------------------------------------------------------------
        # 1. Trigger WAN IP Change Simulation
        # ----------------------------------------------------------------------
        if path_clean == "/api/wan/simulate-ip-change":
            new_ip = body_json.get("ip")
            if not new_ip:
                new_ip = f"{random.randint(11, 198)}.{random.randint(1, 254)}.{random.randint(1, 254)}.{random.randint(2, 250)}"
            old_ip = CURRENT_WAN_IP
            CURRENT_WAN_IP = new_ip
            self._record_audit("WAN_IP_ROTATION", "ALL", old_ip, new_ip, "SIMULATED", "ISP Dynamic IP Transition")
            self._send_json(200, {
                "status": "updated",
                "old_ip": old_ip,
                "new_ip": CURRENT_WAN_IP,
                "message": f"Simulated ISP WAN IP transition to {CURRENT_WAN_IP}"
            })
            return

        # ----------------------------------------------------------------------
        # 2. Trigger API Fault Injection (429 Rate Limit or 500 Internal Error)
        # ----------------------------------------------------------------------
        if path_clean == "/api/wan/simulate-fault":
            SIMULATED_FAULT["enabled"] = bool(body_json.get("enabled", False))
            SIMULATED_FAULT["status_code"] = int(body_json.get("status_code", 500))
            SIMULATED_FAULT["remaining_count"] = int(body_json.get("count", 3))
            SIMULATED_FAULT["error_message"] = body_json.get("message", "Simulated Cloudflare API Error")
            self._send_json(200, {
                "status": "configured",
                "fault": SIMULATED_FAULT
            })
            return

        # ----------------------------------------------------------------------
        # 3. Reset All Records and Audit Logs
        # ----------------------------------------------------------------------
        if path_clean == "/api/dns/reset":
            CURRENT_WAN_IP = "203.0.113.10"
            SIMULATED_FAULT["enabled"] = False
            for z in DNS_ZONES.values():
                for r in z["records"].values():
                    r["content"] = "203.0.113.10"
                    r["modified_on"] = datetime.now(timezone.utc).isoformat()
            AUDIT_LOG.clear()
            self._send_json(200, {"status": "reset", "message": "Reset DNS state to default"})
            return

        # ----------------------------------------------------------------------
        # 4. Cloudflare v4 Create DNS Record: POST /client/v4/zones/{zone_id}/dns_records
        # ----------------------------------------------------------------------
        match_create = re.match(r"^/client/v4/zones/([^/]+)/dns_records$", path_clean)
        if match_create:
            zone_id = match_create.group(1)
            if zone_id not in DNS_ZONES:
                self._send_json(404, {"success": False, "errors": [{"code": 1000, "message": "Zone not found"}]})
                return

            # Check fault simulation
            if SIMULATED_FAULT["enabled"] and (SIMULATED_FAULT["remaining_count"] > 0 or SIMULATED_FAULT["remaining_count"] == -1):
                if SIMULATED_FAULT["remaining_count"] > 0:
                    SIMULATED_FAULT["remaining_count"] -= 1
                code = SIMULATED_FAULT["status_code"]
                self._record_audit("DNS_CREATE_FAILED", body_json.get("name", "unknown"), "", body_json.get("content", ""), "FAILED", f"HTTP {code}")
                self._send_json(code, {"success": False, "errors": [{"code": code, "message": SIMULATED_FAULT["error_message"]}]})
                return

            name = body_json.get("name", "record.example.com")
            rec_id = f"rec_{int(time.time()*1000)}"
            new_record = {
                "id": rec_id,
                "zone_id": zone_id,
                "name": name,
                "type": body_json.get("type", "A"),
                "content": body_json.get("content", CURRENT_WAN_IP),
                "ttl": int(body_json.get("ttl", 120)),
                "proxied": bool(body_json.get("proxied", False)),
                "modified_on": datetime.now(timezone.utc).isoformat()
            }
            DNS_ZONES[zone_id]["records"][rec_id] = new_record
            self._record_audit("DNS_RECORD_CREATED", name, "", new_record["content"], "SUCCESS", "Cloudflare v4 API")
            self._send_json(200, {"success": True, "errors": [], "result": new_record})
            return

        self._send_json(404, {"error": "Not Found", "path": self.path})

    def do_PUT(self):
        global SIMULATED_FAULT
        path_clean = self.path.split("?")[0]
        content_len = int(self.headers.get("Content-Length", 0))
        body_raw = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else "{}"
        try:
            body_json = json.loads(body_raw)
        except Exception:
            body_json = {}

        # ----------------------------------------------------------------------
        # Cloudflare v4 Update Record: PUT /client/v4/zones/{zone_id}/dns_records/{record_id}
        # ----------------------------------------------------------------------
        match_update = re.match(r"^/client/v4/zones/([^/]+)/dns_records/([^/]+)$", path_clean)
        if match_update:
            zone_id = match_update.group(1)
            record_id = match_update.group(2)
            if zone_id not in DNS_ZONES:
                self._send_json(404, {"success": False, "errors": [{"code": 1000, "message": "Zone not found"}]})
                return

            zone = DNS_ZONES[zone_id]
            if record_id not in zone["records"]:
                self._send_json(404, {"success": False, "errors": [{"code": 81044, "message": "Record not found"}]})
                return

            # Check fault simulation
            if SIMULATED_FAULT["enabled"] and (SIMULATED_FAULT["remaining_count"] > 0 or SIMULATED_FAULT["remaining_count"] == -1):
                if SIMULATED_FAULT["remaining_count"] > 0:
                    SIMULATED_FAULT["remaining_count"] -= 1
                code = SIMULATED_FAULT["status_code"]
                rec = zone["records"][record_id]
                self._record_audit("DNS_UPDATE_FAILED", rec["name"], rec["content"], body_json.get("content", ""), "FAILED", f"HTTP {code} Outage")
                self._send_json(code, {"success": False, "errors": [{"code": code, "message": SIMULATED_FAULT["error_message"]}]})
                return

            rec = zone["records"][record_id]
            old_ip = rec["content"]
            new_ip = body_json.get("content", old_ip)
            rec["content"] = new_ip
            rec["ttl"] = int(body_json.get("ttl", rec["ttl"]))
            rec["proxied"] = bool(body_json.get("proxied", rec["proxied"]))
            rec["modified_on"] = datetime.now(timezone.utc).isoformat()

            self._record_audit("DNS_RECORD_UPDATED", rec["name"], old_ip, new_ip, "SUCCESS", "Cloudflare v4 API PUT")
            self._send_json(200, {
                "success": True,
                "errors": [],
                "messages": [],
                "result": rec
            })
            return

        self._send_json(404, {"error": "Not Found", "path": self.path})

    def log_message(self, format, *args):
        sys.stdout.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [MockDNS] " + (format % args) + "\n")
        sys.stdout.flush()

def run():
    server = ThreadingSimpleServer(("0.0.0.0", PORT), MockDNSHandler)
    print(f"🌐 Mock DNS & WAN IP Discovery Server listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    run()
