#!/usr/bin/env python3
# ==============================================================================
# server.py - Python Self-Service Cloud Sandbox Provisioning Portal
# ==============================================================================
# Provides a REST API wrapping Terraform / OpenTofu CLI with a background
# worker monitoring TTL timers for automatic cloud sandbox teardown.
# ==============================================================================

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

STATUS_PROVISIONING = "PROVISIONING"
STATUS_READY = "READY"
STATUS_FAILED = "FAILED"
STATUS_DESTROYING = "DESTROYING"
STATUS_DESTROYED = "DESTROYED"


class SandboxStore:
    def __init__(self, data_file):
        self.lock = threading.RLock()
        self.data_file = data_file
        self.sandboxes = {}
        self.load()

    def save(self, sbx):
        with self.lock:
            self.sandboxes[sbx["id"]] = sbx
            self.persist()

    def get(self, sbx_id):
        with self.lock:
            sbx = self.sandboxes.get(sbx_id)
            if sbx:
                self._compute_remaining(sbx)
            return sbx

    def list(self):
        with self.lock:
            result = []
            for sbx in self.sandboxes.values():
                self._compute_remaining(sbx)
                result.append(sbx)
            return result

    def count_active(self):
        with self.lock:
            return sum(
                1 for s in self.sandboxes.values()
                if s["status"] in [STATUS_READY, STATUS_PROVISIONING]
            )

    def _compute_remaining(self, sbx):
        if sbx["status"] in [STATUS_DESTROYED, STATUS_FAILED]:
            sbx["time_remaining_seconds"] = 0
            return
        now_ts = datetime.now(timezone.utc).timestamp()
        expires_ts = datetime.fromisoformat(sbx["expires_at"]).timestamp()
        rem = int(expires_ts - now_ts)
        sbx["time_remaining_seconds"] = max(0, rem)

    def persist(self):
        if not self.data_file:
            return
        os.makedirs(os.path.dirname(os.path.abspath(self.data_file)), exist_ok=True)
        with open(self.data_file, "w", encoding="utf-8") as f:
            json.dump(self.sandboxes, f, indent=2)

    def load(self):
        if self.data_file and os.path.exists(self.data_file):
            try:
                with open(self.data_file, "r", encoding="utf-8") as f:
                    self.sandboxes = json.load(f)
            except Exception:
                self.sandboxes = {}


class IaCEngine:
    def __init__(self, templates_dir, workspaces_dir, logs_dir):
        self.templates_dir = os.path.abspath(templates_dir)
        self.workspaces_dir = os.path.abspath(workspaces_dir)
        self.logs_dir = os.path.abspath(logs_dir)
        self.binary = "tofu" if shutil.which("tofu") else "terraform"
        os.makedirs(self.workspaces_dir, exist_ok=True)
        os.makedirs(self.logs_dir, exist_ok=True)

    def provision(self, sbx, params=None):
        sbx_id = sbx["id"]
        template = sbx["template"]
        tmpl_path = os.path.join(self.templates_dir, template)
        workspace_path = os.path.join(self.workspaces_dir, sbx_id)
        log_path = os.path.join(self.logs_dir, f"{sbx_id}.log")

        sbx["workspace_dir"] = workspace_path
        sbx["log_file"] = log_path

        if not os.path.isdir(tmpl_path):
            raise FileNotFoundError(f"Template '{template}' not found at {tmpl_path}")

        # Copy template files
        if os.path.exists(workspace_path):
            shutil.rmtree(workspace_path)
        shutil.copytree(tmpl_path, workspace_path, ignore=shutil.ignore_patterns(".terraform*"))

        # Write vars
        tfvars = {
            "sandbox_id": sbx_id,
            "developer_email": sbx["developer_email"],
        }
        if params:
            tfvars.update(params)

        with open(os.path.join(workspace_path, "terraform.tfvars.json"), "w") as f:
            json.dump(tfvars, f, indent=2)

        with open(log_path, "a") as logf:
            # Init
            res = subprocess.run([self.binary, "init", "-no-color"], cwd=workspace_path, stdout=logf, stderr=logf)
            if res.returncode != 0:
                raise RuntimeError(f"terraform init failed with code {res.returncode}")

            # Apply
            res = subprocess.run([self.binary, "apply", "-auto-approve", "-no-color"], cwd=workspace_path, stdout=logf, stderr=logf)
            if res.returncode != 0:
                raise RuntimeError(f"terraform apply failed with code {res.returncode}")

            # Outputs
            out_res = subprocess.run([self.binary, "output", "-json"], cwd=workspace_path, capture_output=True, text=True)
            if out_res.returncode == 0:
                raw_out = json.loads(out_res.stdout)
                sbx["outputs"] = {k: v.get("value") for k, v in raw_out.items()}

    def destroy(self, sbx):
        workspace_path = sbx.get("workspace_dir")
        if not workspace_path or not os.path.isdir(workspace_path):
            return

        log_path = sbx.get("log_file", os.path.join(self.logs_dir, f"{sbx['id']}.log"))
        with open(log_path, "a") as logf:
            subprocess.run([self.binary, "destroy", "-auto-approve", "-no-color"], cwd=workspace_path, stdout=logf, stderr=logf)


class TTLWorker(threading.Thread):
    def __init__(self, store, engine, interval=1.0):
        super().__init__(daemon=True)
        self.store = store
        self.engine = engine
        self.interval = interval
        self.running = True

    def run(self):
        print(f"[Worker] Background TTL Worker started (interval: {self.interval}s)")
        while self.running:
            sandboxes = self.store.list()
            now_ts = datetime.now(timezone.utc).timestamp()

            for sbx in sandboxes:
                if sbx["status"] == STATUS_READY:
                    exp_ts = datetime.fromisoformat(sbx["expires_at"]).timestamp()
                    if now_ts >= exp_ts:
                        print(f"[Worker] ⏰ Sandbox {sbx['id']} EXPIRED. Running automated teardown...")
                        sbx["status"] = STATUS_DESTROYING
                        self.store.save(sbx)

                        def do_destroy(target):
                            try:
                                self.engine.destroy(target)
                                target["status"] = STATUS_DESTROYED
                                print(f"[Worker] ✅ Sandbox {target['id']} destroyed successfully.")
                            except Exception as e:
                                target["status"] = STATUS_FAILED
                                target["error_message"] = str(e)
                                print(f"[Worker] ❌ Failed to destroy {target['id']}: {e}")
                            self.store.save(target)

                        threading.Thread(target=do_destroy, args=(sbx,), daemon=True).start()

            time.sleep(self.interval)

    def stop(self):
        self.running = False


class PortalHTTPHandler(BaseHTTPRequestHandler):
    store = None
    engine = None

    def _set_headers(self, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_OPTIONS(self):
        self._set_headers(200)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/healthz":
            resp = {
                "status": "healthy",
                "version": "1.0.0",
                "active_sandboxes": self.store.count_active(),
                "total_sandboxes": len(self.store.list()),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
            self._set_headers(200)
            self.wfile.write(json.dumps(resp).encode("utf-8"))
            return

        if path in ["/api/v1/sandboxes", "/sandboxes"]:
            sandboxes = self.store.list()
            resp = {
                "total": len(sandboxes),
                "active": self.store.count_active(),
                "sandboxes": sandboxes,
            }
            self._set_headers(200)
            self.wfile.write(json.dumps(resp).encode("utf-8"))
            return

        if path.startswith("/api/v1/sandboxes/") or path.startswith("/sandboxes/"):
            sbx_id = path.split("/")[-1]
            sbx = self.store.get(sbx_id)
            if not sbx:
                self._set_headers(404)
                self.wfile.write(json.dumps({"error": f"Sandbox '{sbx_id}' not found"}).encode("utf-8"))
                return
            self._set_headers(200)
            self.wfile.write(json.dumps(sbx).encode("utf-8"))
            return

        self._set_headers(404)
        self.wfile.write(b'{"error":"Not Found"}')

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path in ["/api/v1/sandboxes", "/sandboxes"]:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length > 0 else b"{}"
            try:
                data = json.loads(body)
            except Exception:
                data = {}

            sbx_id = f"sbx-{uuid.uuid4().hex[:8]}"
            ttl_seconds = int(data.get("ttl_seconds", 120))
            now = datetime.now(timezone.utc)
            expires_at = datetime.fromtimestamp(now.timestamp() + ttl_seconds, tz=timezone.utc)

            sbx = {
                "id": sbx_id,
                "name": data.get("name", "ephemeral-sandbox"),
                "developer_email": data.get("developer_email", "developer@company.local"),
                "template": data.get("template", "web-app"),
                "ttl_seconds": ttl_seconds,
                "status": STATUS_PROVISIONING,
                "created_at": now.isoformat(),
                "expires_at": expires_at.isoformat(),
                "time_remaining_seconds": ttl_seconds,
                "outputs": {},
            }
            self.store.save(sbx)

            print(f"[API] Provisioning sandbox {sbx_id} (Template: {sbx['template']}, TTL: {ttl_seconds}s)...")
            try:
                self.engine.provision(sbx, data.get("parameters"))
                sbx["status"] = STATUS_READY
                self.store.save(sbx)
                print(f"[API] ✅ Sandbox {sbx_id} READY.")
                self._set_headers(201)
                self.wfile.write(json.dumps(sbx).encode("utf-8"))
            except Exception as e:
                sbx["status"] = STATUS_FAILED
                sbx["error_message"] = str(e)
                self.store.save(sbx)
                print(f"[API] ❌ Failed to provision {sbx_id}: {e}")
                self._set_headers(500)
                self.wfile.write(json.dumps(sbx).encode("utf-8"))
            return

        self._set_headers(404)
        self.wfile.write(b'{"error":"Not Found"}')

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path.startswith("/api/v1/sandboxes/") or path.startswith("/sandboxes/"):
            sbx_id = path.split("/")[-1]
            sbx = self.store.get(sbx_id)
            if not sbx:
                self._set_headers(404)
                self.wfile.write(json.dumps({"error": f"Sandbox '{sbx_id}' not found"}).encode("utf-8"))
                return

            if sbx["status"] == STATUS_DESTROYED:
                self._set_headers(200)
                self.wfile.write(json.dumps({"message": "Already destroyed", "status": STATUS_DESTROYED}).encode("utf-8"))
                return

            print(f"[API] 🗑️ Manual destruction requested for {sbx_id}...")
            sbx["status"] = STATUS_DESTROYING
            self.store.save(sbx)

            try:
                self.engine.destroy(sbx)
                sbx["status"] = STATUS_DESTROYED
                sbx["time_remaining_seconds"] = 0
                self.store.save(sbx)
                print(f"[API] ✅ Sandbox {sbx_id} destroyed.")
                self._set_headers(200)
                self.wfile.write(json.dumps({"message": f"Sandbox {sbx_id} destroyed", "sandbox": sbx}).encode("utf-8"))
            except Exception as e:
                sbx["status"] = STATUS_FAILED
                sbx["error_message"] = str(e)
                self.store.save(sbx)
                self._set_headers(500)
                self.wfile.write(json.dumps(sbx).encode("utf-8"))
            return

        self._set_headers(404)
        self.wfile.write(b'{"error":"Not Found"}')

    def log_message(self, format, *args):
        pass  # Suppress default HTTP logging to keep console clean


def main():
    parser = argparse.ArgumentParser(description="Self-Service Cloud Sandbox Provisioning Portal")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8080)), help="Listening port")
    parser.add_argument("--base-dir", default=".", help="Base project directory")
    args = parser.parse_args()

    base_dir = os.path.abspath(args.base_dir)
    data_file = os.path.join(base_dir, "data", "sandboxes.json")
    templates_dir = os.path.join(base_dir, "templates")
    workspaces_dir = os.path.join(base_dir, "workspaces")
    logs_dir = os.path.join(base_dir, "logs")

    store = SandboxStore(data_file)
    engine = IaCEngine(templates_dir, workspaces_dir, logs_dir)
    worker = TTLWorker(store, engine, interval=1.0)
    worker.start()

    PortalHTTPHandler.store = store
    PortalHTTPHandler.engine = engine

    server = HTTPServer(("0.0.0.0", args.port), PortalHTTPHandler)
    print(f"======================================================================")
    print(f"  🚀 Python Self-Service Cloud Sandbox Portal listening on http://127.0.0.1:{args.port}")
    print(f"======================================================================")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        worker.stop()
        server.server_close()


if __name__ == "__main__":
    main()
