#!/usr/bin/env python3
"""
Interpreted Distroless Demo
===========================
Runs on gcr.io/distroless/python3-debian12:nonroot.
Provides Python runtime with zero shell, zero package manager, and nonroot execution.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.getenv("PORT", "8080"))
START_TIME = time.time()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()

        payload = {
            "runtime": "python3-distroless",
            "uptime_seconds": round(time.time() - START_TIME, 2),
            "uid": os.getuid() if hasattr(os, "getuid") else 0,
            "is_non_root": (os.getuid() != 0) if hasattr(os, "getuid") else False,
            "shell_present": os.path.exists("/bin/sh") or os.path.exists("/bin/bash"),
        }
        self.wfile.write(json.dumps(payload, indent=2).encode("utf-8"))


if __name__ == "__main__":
    server = HTTPServer(("", PORT), Handler)
    print(f"Python Distroless server running on port {PORT} (UID: {os.getuid() if hasattr(os, 'getuid') else 0})")
    server.serve_forever()
