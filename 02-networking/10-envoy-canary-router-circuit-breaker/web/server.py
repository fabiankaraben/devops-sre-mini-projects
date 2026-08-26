#!/usr/bin/env python3
"""
Lightweight Web Server hosting the Envoy Canary & Circuit Breaker Dashboard
"""

import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

PORT = int(os.environ.get("PORT", 8080))
WEB_DIR = os.path.dirname(os.path.abspath(__file__))

class CustomDashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"healthy","service":"canary-dashboard"}\n')
            return
        return super().do_GET()

    def log_message(self, format, *args):
        pass

def run():
    server = HTTPServer(("0.0.0.0", PORT), CustomDashboardHandler)
    print(f"📊 Canary Dashboard serving on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    run()
