#!/usr/bin/env python3
"""
Shadow Experimental API Service (v2.0.0-rc1)
Listens on port 8002. Handles mirrored / dark traffic duplicated asynchronously by Nginx.
Verifies payload and header replication, provides simulation controls for latency and fault isolation,
and calculates traffic diff metrics against the primary service.
"""

import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", 8002))
PRIMARY_HOST = os.environ.get("PRIMARY_HOST", "primary-api:8001")
SERVICE_NAME = "shadow-api"
SERVICE_VERSION = "v2.0.0-rc1"

START_TIME = time.time()
SHADOW_AUDIT_LOG = []
SIMULATED_DELAY_SEC = 0.0
SIMULATED_ERROR_ENABLED = False
SIMULATED_ERROR_STATUS = 500

class ThreadingSimpleServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class ShadowAPIHandler(BaseHTTPRequestHandler):
    server_version = "ShadowAPI/2.0.0-rc1"

    def _send_json(self, status_code, data, extra_headers=None):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Service-Name", SERVICE_NAME)
        self.send_header("X-Service-Version", SERVICE_VERSION)
        self.send_header("X-Shadow-Mirror", "processed")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Request-ID, X-Shadow-Mirror")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self._send_json(200, {"status": "ok"})

    def _record_shadow_audit(self, method, path, body=None, latency_ms=0.0):
        req_id = self.headers.get("X-Request-ID", f"shadow-gen-{int(time.time() * 1000)}-{len(SHADOW_AUDIT_LOG)}")
        is_mirrored = (self.headers.get("X-Shadow-Mirror") == "true")
        audit_entry = {
            "request_id": req_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "method": method,
            "path": path,
            "is_mirrored": is_mirrored,
            "client_ip": self.client_address[0],
            "headers": {k: self.headers[k] for k in self.headers},
            "body": body,
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "processing_latency_ms": round(latency_ms, 2)
        }
        SHADOW_AUDIT_LOG.append(audit_entry)
        if len(SHADOW_AUDIT_LOG) > 500:
            SHADOW_AUDIT_LOG.pop(0)
        return req_id

    def _apply_simulations(self):
        global SIMULATED_DELAY_SEC, SIMULATED_ERROR_ENABLED, SIMULATED_ERROR_STATUS
        if SIMULATED_DELAY_SEC > 0:
            time.sleep(SIMULATED_DELAY_SEC)
        if SIMULATED_ERROR_ENABLED:
            return SIMULATED_ERROR_STATUS
        return 200

    def do_GET(self):
        req_start = time.time()
        path = self.path.split("?")[0]

        if path == "/health":
            self._send_json(200, {
                "status": "healthy",
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "total_mirrored_requests": len(SHADOW_AUDIT_LOG),
                "simulated_delay_seconds": SIMULATED_DELAY_SEC,
                "simulated_error_enabled": SIMULATED_ERROR_ENABLED
            })
            return

        if path in ("/api/shadow/stats", "/api/stats"):
            get_count = sum(1 for r in SHADOW_AUDIT_LOG if r["method"] == "GET")
            post_count = sum(1 for r in SHADOW_AUDIT_LOG if r["method"] == "POST")
            self._send_json(200, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "total_mirrored_requests": len(SHADOW_AUDIT_LOG),
                "get_count": get_count,
                "post_count": post_count,
                "simulated_delay_sec": SIMULATED_DELAY_SEC,
                "simulated_error_enabled": SIMULATED_ERROR_ENABLED,
                "recent_requests": SHADOW_AUDIT_LOG[-100:]
            })
            return

        if path == "/api/shadow/audit":
            self._send_json(200, {
                "service": SERVICE_NAME,
                "version": SERVICE_VERSION,
                "total_entries": len(SHADOW_AUDIT_LOG),
                "entries": SHADOW_AUDIT_LOG
            })
            return

        if path == "/api/shadow/diff":
            # Compare shadow requests with primary requests
            diff_result = self._calculate_traffic_diff()
            self._send_json(200, diff_result)
            return

        # Check simulated faults/delays on API endpoints
        sim_status = self._apply_simulations()
        elapsed_ms = (time.time() - req_start) * 1000
        req_id = self._record_shadow_audit("GET", self.path, latency_ms=elapsed_ms)

        if sim_status >= 400:
            self._send_json(sim_status, {
                "error": "Simulated Shadow Backend Error",
                "service": SERVICE_NAME,
                "status_code": sim_status,
                "request_id": req_id
            })
            return

        self._send_json(200, {
            "message": "Shadow API processed mirrored GET request",
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "path": self.path,
            "request_id": req_id,
            "shadow_latency_ms": round(elapsed_ms, 2)
        })

    def do_POST(self):
        global SIMULATED_DELAY_SEC, SIMULATED_ERROR_ENABLED, SIMULATED_ERROR_STATUS
        req_start = time.time()
        path = self.path.split("?")[0]

        # Read JSON body
        content_length = int(self.headers.get("Content-Length", 0))
        body_raw = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            body_json = json.loads(body_raw)
        except Exception:
            body_json = {"raw": body_raw}

        # Simulation configuration endpoints
        if path == "/api/shadow/simulate-delay":
            delay = float(body_json.get("delay_seconds", 0.0))
            if delay < 0:
                delay = 0.0
            SIMULATED_DELAY_SEC = delay
            self._send_json(200, {
                "status": "configured",
                "service": SERVICE_NAME,
                "simulated_delay_seconds": SIMULATED_DELAY_SEC,
                "message": f"Shadow processing delay set to {SIMULATED_DELAY_SEC}s"
            })
            return

        if path == "/api/shadow/simulate-error":
            enabled = bool(body_json.get("enable", False))
            status_code = int(body_json.get("status_code", 500))
            SIMULATED_ERROR_ENABLED = enabled
            SIMULATED_ERROR_STATUS = status_code
            self._send_json(200, {
                "status": "configured",
                "service": SERVICE_NAME,
                "simulated_error_enabled": SIMULATED_ERROR_ENABLED,
                "simulated_error_status": SIMULATED_ERROR_STATUS,
                "message": f"Shadow fault simulation set to {SIMULATED_ERROR_ENABLED} ({SIMULATED_ERROR_STATUS})"
            })
            return

        if path == "/api/reset":
            SHADOW_AUDIT_LOG.clear()
            SIMULATED_DELAY_SEC = 0.0
            SIMULATED_ERROR_ENABLED = False
            self._send_json(200, {"status": "reset", "service": SERVICE_NAME, "message": "Shadow audit logs and simulations cleared"})
            return

        # Check simulated faults/delays on regular mirrored API calls
        sim_status = self._apply_simulations()
        elapsed_ms = (time.time() - req_start) * 1000
        req_id = self._record_shadow_audit("POST", self.path, body_json, latency_ms=elapsed_ms)

        if sim_status >= 400:
            self._send_json(sim_status, {
                "error": "Simulated Shadow Backend Error",
                "service": SERVICE_NAME,
                "status_code": sim_status,
                "request_id": req_id
            })
            return

        self._send_json(201, {
            "status": "shadow_processed",
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "path": self.path,
            "request_id": req_id,
            "received_payload": body_json,
            "shadow_latency_ms": round(elapsed_ms, 2)
        })

    def _calculate_traffic_diff(self):
        try:
            req = urllib.request.Request(f"http://{PRIMARY_HOST}/api/stats", headers={"User-Agent": "ShadowDiffChecker/1.0"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                primary_data = json.loads(resp.read().decode("utf-8"))
                primary_requests = primary_data.get("recent_requests", [])
        except Exception as e:
            return {
                "status": "error",
                "message": f"Failed to reach primary service at {PRIMARY_HOST}: {str(e)}"
            }

        primary_map = {r["request_id"]: r for r in primary_requests if "request_id" in r}
        shadow_map = {r["request_id"]: r for r in SHADOW_AUDIT_LOG if "request_id" in r}

        matched_count = 0
        mismatched_payloads = []
        missing_in_shadow = []

        for req_id, p_req in primary_map.items():
            if req_id in shadow_map:
                s_req = shadow_map[req_id]
                p_body = json.dumps(p_req.get("body"), sort_keys=True)
                s_body = json.dumps(s_req.get("body"), sort_keys=True)
                if p_body == s_body:
                    matched_count += 1
                else:
                    mismatched_payloads.append({
                        "request_id": req_id,
                        "primary_body": p_req.get("body"),
                        "shadow_body": s_req.get("body")
                    })
            else:
                missing_in_shadow.append(req_id)

        total_primary = len(primary_map)
        replication_pct = (matched_count / total_primary * 100.0) if total_primary > 0 else 100.0

        return {
            "status": "success",
            "primary_requests_count": total_primary,
            "shadow_requests_count": len(shadow_map),
            "matched_requests_count": matched_count,
            "missing_in_shadow_count": len(missing_in_shadow),
            "mismatched_payloads_count": len(mismatched_payloads),
            "replication_accuracy_percent": round(replication_pct, 2),
            "mismatches": mismatched_payloads[:10],
            "missing_request_ids": missing_in_shadow[:10]
        }

    def log_message(self, format, *args):
        sys.stdout.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{SERVICE_NAME}] " + (format % args) + "\n")
        sys.stdout.flush()

def run():
    server = ThreadingSimpleServer(("0.0.0.0", PORT), ShadowAPIHandler)
    print(f"👻 {SERVICE_NAME} ({SERVICE_VERSION}) listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    run()
