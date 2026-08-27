#!/usr/bin/env python3
"""
test_lifecycle.py - Automated Unit & Integration Tests for Lifecycle Draining
=============================================================================
Tests signal handling, readiness probe state transitions, in-flight request
completion during shutdown, and comparative failure modes without external dependencies.
"""

import json
import os
import signal
import subprocess
import threading
import time
import unittest
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


class TestGracefulLifecycle(unittest.TestCase):

    def test_readiness_and_status_endpoints(self):
        """Verifies /healthz, /readyz, and /status endpoints during normal operation."""
        proc = subprocess.Popen(
            [sys.executable, os.path.join(SCRIPT_DIR, "graceful_server.py"), "--port", "8091", "--mode", "graceful"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        try:
            time.sleep(0.8)

            # Check /healthz
            with urllib.request.urlopen("http://127.0.0.1:8091/healthz", timeout=3.0) as resp:
                self.assertEqual(resp.status, 200)
                data = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(data.get("status"), "ALIVE")

            # Check /readyz
            with urllib.request.urlopen("http://127.0.0.1:8091/readyz", timeout=3.0) as resp:
                self.assertEqual(resp.status, 200)
                data = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(data.get("status"), "READY")

            # Check /status
            with urllib.request.urlopen("http://127.0.0.1:8091/status", timeout=3.0) as resp:
                self.assertEqual(resp.status, 200)
                data = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(data.get("state"), "RUNNING")
                self.assertEqual(data.get("mode"), "graceful")

        finally:
            proc.terminate()
            proc.wait(timeout=3.0)

    def test_standalone_graceful_draining(self):
        """Verifies that in-flight requests complete cleanly (200 OK) when SIGTERM arrives."""
        proc = subprocess.Popen(
            [
                sys.executable,
                os.path.join(SCRIPT_DIR, "graceful_server.py"),
                "--port", "8092",
                "--mode", "graceful",
                "--grace-timeout", "10.0",
                "--work-delay-ms", "600",
            ],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        time.sleep(0.8)

        results = []
        errors = []

        def worker(idx):
            try:
                req = urllib.request.Request("http://127.0.0.1:8092/api/v1/work", headers={"Connection": "close"})
                with urllib.request.urlopen(req, timeout=5.0) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
                    results.append((resp.status, payload))
            except Exception as e:
                errors.append((type(e).__name__, str(e)))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(5)]
        for t in threads:
            t.start()

        # Allow requests to enter in-flight work state
        time.sleep(0.2)

        # Send SIGTERM to trigger graceful draining
        proc.send_signal(signal.SIGTERM)

        for t in threads:
            t.join(timeout=5.0)

        proc.wait(timeout=5.0)

        # Assert all 5 requests completed with HTTP 200
        self.assertEqual(len(results), 5, f"Expected 5 successful responses, got {len(results)}")
        self.assertEqual(len(errors), 0, f"Expected 0 errors during draining, got {errors}")
        for status, payload in results:
            self.assertEqual(status, 200)
            self.assertEqual(payload.get("status"), "COMPLETED")
        self.assertEqual(proc.returncode, 0, "Server should exit with return code 0")

    def test_standalone_naive_termination_aborts_connections(self):
        """Verifies that naive mode cuts off in-flight requests when SIGTERM arrives."""
        proc = subprocess.Popen(
            [
                sys.executable,
                os.path.join(SCRIPT_DIR, "graceful_server.py"),
                "--port", "8093",
                "--mode", "naive",
                "--work-delay-ms", "600",
            ],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        time.sleep(0.8)

        results = []
        errors = []

        def worker(idx):
            try:
                req = urllib.request.Request("http://127.0.0.1:8093/api/v1/work", headers={"Connection": "close"})
                with urllib.request.urlopen(req, timeout=5.0) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
                    results.append((resp.status, payload))
            except Exception as e:
                errors.append((type(e).__name__, str(e)))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(5)]
        for t in threads:
            t.start()

        time.sleep(0.2)
        proc.send_signal(signal.SIGTERM)

        for t in threads:
            t.join(timeout=5.0)

        proc.wait(timeout=5.0)

        # In naive mode, active requests MUST fail because socket is abruptly closed
        self.assertGreater(len(errors), 0, "Expected socket abort errors in naive mode")
        self.assertNotEqual(proc.returncode, 0, "Naive mode should exit abruptly with non-zero code")


if __name__ == "__main__":
    import sys
    unittest.main(verbosity=2)
