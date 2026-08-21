#!/usr/bin/env python3
"""
flaky_service.py - Mock HTTP Service for Failure & Supervisor Testing

Simulates a real-world microservice with endpoints to inspect health,
trigger intentional hard crashes, and simulate deadlocks/unresponsive hangs.
"""

import argparse
import http.server
import json
import os
import signal
import sys
import threading
import time

# Service state
START_TIME = time.time()
IS_HANGING = False
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PID_FILE_PATH = os.path.join(BASE_DIR, "flaky_service.pid")


class FlakyHTTPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Concise logging format
        print(f"[flaky_service] {self.address_string()} - {format % args}", flush=True)

    def do_GET(self):
        global IS_HANGING
        if IS_HANGING and self.path != "/unhang":
            # Simulate deadlock/hang: sleep indefinitely until timeout
            print("[flaky_service] Request received while in HANGING state. Blocking...", flush=True)
            time.sleep(30)
            return

        if self.path in ("/", "/healthz", "/health"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            uptime = round(time.time() - START_TIME, 2)
            payload = {
                "status": "healthy",
                "uptime_seconds": uptime,
                "pid": os.getpid(),
                "timestamp": time.time()
            }
            self.wfile.write(json.dumps(payload).encode("utf-8"))

        elif self.path == "/crash":
            print("[flaky_service] Triggering intentional CRASH via /crash endpoint...", flush=True)
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error": "Simulated fatal crash", "status": "CRASHING"}')
            self.wfile.flush()
            # Hard exit without standard cleanup to simulate fatal segfault/panic
            threading.Thread(target=lambda: (time.sleep(0.1), os._exit(1))).start()

        elif self.path == "/hang":
            IS_HANGING = True
            print("[flaky_service] Service entered DEADLOCK / HANGING state.", flush=True)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status": "hanging", "message": "Subsequent health checks will time out"}')

        elif self.path == "/unhang":
            IS_HANGING = False
            print("[flaky_service] Service cleared HANGING state.", flush=True)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status": "recovered"}')

        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"error": "Endpoint not found"}')

    def do_POST(self):
        # Support POST method on the same endpoints
        self.do_GET()


def signal_handler(signum, frame):
    print(f"\n[flaky_service] Received signal {signum}. Shutting down cleanly...", flush=True)
    if os.path.exists(PID_FILE_PATH):
        try:
            os.remove(PID_FILE_PATH)
        except OSError:
            pass
    sys.exit(0)


def main():
    global PID_FILE_PATH

    parser = argparse.ArgumentParser(description="Flaky HTTP Service for Process Watchdog Testing")
    parser.add_argument("--port", type=int, default=8080, help="HTTP port to listen on (default: 8080)")
    parser.add_argument("--host", default="127.0.0.1", help="Host interface to bind (default: 127.0.0.1)")
    parser.add_argument("--pid-file", default=PID_FILE_PATH, help="Path to PID file")

    args = parser.parse_args()
    PID_FILE_PATH = args.pid_file

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Write current PID to PID file
    with open(PID_FILE_PATH, "w") as f:
        f.write(str(os.getpid()))

    server_address = (args.host, args.port)
    httpd = http.server.HTTPServer(server_address, FlakyHTTPHandler)

    print("=" * 55)
    print("  Flaky HTTP Service (DevOps / SRE Mini-Project)")
    print("=" * 55)
    print(f"PID        : {os.getpid()}")
    print(f"Listening  : http://{args.host}:{args.port}")
    print(f"PID File   : {os.path.abspath(PID_FILE_PATH)}")
    print("Endpoints  : /healthz, /crash, /hang, /unhang")
    print("=" * 55, flush=True)

    try:
        httpd.serve_forever()
    finally:
        if os.path.exists(PID_FILE_PATH):
            try:
                os.remove(PID_FILE_PATH)
            except OSError:
                pass


if __name__ == "__main__":
    main()
