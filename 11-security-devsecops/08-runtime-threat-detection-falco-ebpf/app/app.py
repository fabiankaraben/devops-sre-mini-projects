#!/usr/bin/env python3
"""
Victim Microservice Application.
Simulates an enterprise container workload monitored in real time by Falco eBPF probes.
"""

import os
import sys
import http.server
import socketserver

PORT = int(os.getenv("PORT", 8080))


class SimpleHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"healthy","service":"payment-gateway"}\n')
        else:
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"service":"payment-gateway","monitored_by":"Falco-eBPF"}\n')

    def log_message(self, format, *args):
        # Suppress noisy HTTP logs during testing
        pass


if __name__ == "__main__":
    print(f"Starting Payment Gateway service on port {PORT}...")
    with socketserver.TCPServer(("", PORT), SimpleHandler) as httpd:
        httpd.serve_forever()
