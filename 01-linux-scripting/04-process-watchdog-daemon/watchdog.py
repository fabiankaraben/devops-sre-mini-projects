#!/usr/bin/env python3
"""
watchdog.py - Production-grade Process Supervisor & Watchdog Daemon

Monitors child processes via L1 (PID/Process status) and L7 (HTTP health probe),
automatically restarts failed services, prevents crash flapping with sliding-window
rate limiting, emits structured JSON status, and fires webhook alerts.
"""

import argparse
import datetime
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Global daemon state
RUNNING = True
CHILD_PROC = None
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATUS_FILE_PATH = os.path.join(BASE_DIR, "watchdog_status.json")
WATCHDOG_PID_FILE = os.path.join(BASE_DIR, "watchdog.pid")


class ProcessSupervisor:
    def __init__(
        self,
        command: str,
        http_check_url: str = None,
        check_interval: float = 2.0,
        max_restarts: int = 3,
        window_seconds: int = 60,
        http_timeout: float = 2.0,
        webhook_url: str = None,
        status_file: str = STATUS_FILE_PATH
    ):
        self.command = command
        self.http_check_url = http_check_url
        self.check_interval = check_interval
        self.max_restarts = max_restarts
        self.window_seconds = window_seconds
        self.http_timeout = http_timeout
        self.webhook_url = webhook_url
        self.status_file = status_file

        self.child_process = None
        self.state = "STARTING"  # STARTING, HEALTHY, UNHEALTHY, RESTARTING, FLAPPING, STOPPED
        self.start_time = time.time()
        self.service_start_time = 0.0
        self.total_restarts = 0
        self.restart_timestamps = []
        self.consecutive_failures = 0
        self.last_error = ""

    def log(self, level: str, message: str):
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        print(f"[{timestamp}] [{level}] [Watchdog] {message}", flush=True)

    def send_webhook_alert(self, event_type: str, details: dict):
        if not self.webhook_url:
            return

        payload = {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "event": event_type,
            "state": self.state,
            "command": self.command,
            "child_pid": self.child_process.pid if self.child_process else None,
            "total_restarts": self.total_restarts,
            "details": details
        }
        try:
            req = urllib.request.Request(
                self.webhook_url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=3.0)
            self.log("INFO", f"Webhook alert sent successfully to {self.webhook_url}")
        except Exception as e:
            self.log("WARN", f"Failed to deliver webhook alert: {e}")

    def update_status_file(self):
        recent_restarts = self.get_recent_restart_count()
        uptime = round(time.time() - self.service_start_time, 2) if self.service_start_time > 0 else 0.0
        payload = {
            "watchdog_pid": os.getpid(),
            "state": self.state,
            "command": self.command,
            "child_pid": self.child_process.pid if (self.child_process and self.child_process.poll() is None) else None,
            "service_uptime_seconds": uptime,
            "total_restarts": self.total_restarts,
            "restarts_in_window": recent_restarts,
            "max_restarts_allowed": self.max_restarts,
            "window_seconds": self.window_seconds,
            "flapping": (self.state == "FLAPPING"),
            "last_error": self.last_error,
            "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat()
        }
        try:
            with open(self.status_file, "w") as f:
                json.dump(payload, f, indent=2)
        except OSError:
            pass

    def get_recent_restart_count(self) -> int:
        now = time.time()
        self.restart_timestamps = [t for t in self.restart_timestamps if (now - t) <= self.window_seconds]
        return len(self.restart_timestamps)

    def start_child(self) -> bool:
        self.log("INFO", f"Spawning supervised process: '{self.command}'")
        try:
            # Spawn in own process group for clean signal management
            self.child_process = subprocess.Popen(
                self.command,
                shell=True,
                preexec_fn=os.setsid if hasattr(os, "setsid") else None
            )
            self.service_start_time = time.time()
            self.state = "STARTING"
            self.consecutive_failures = 0
            self.log("INFO", f"Process started successfully with PID {self.child_process.pid}")
            self.update_status_file()
            return True
        except Exception as e:
            self.last_error = f"Failed to spawn process: {e}"
            self.log("ERROR", self.last_error)
            self.state = "UNHEALTHY"
            self.update_status_file()
            return False

    def check_l1_pid(self) -> bool:
        """Checks if process is alive at OS level (L1)."""
        if not self.child_process:
            return False
        return self.child_process.poll() is None

    def check_l7_http(self) -> bool:
        """Checks application responsiveness via HTTP probe (L7)."""
        if not self.http_check_url:
            return True

        # Allow 1.0 second startup grace period before probing
        if (time.time() - self.service_start_time) < 1.0:
            return True

        try:
            req = urllib.request.Request(self.http_check_url, headers={"User-Agent": "Watchdog-Probe/1.0"})
            with urllib.request.urlopen(req, timeout=self.http_timeout) as response:
                return response.status == 200
        except Exception as e:
            self.last_error = f"HTTP probe failure ({self.http_check_url}): {e}"
            return False

    def kill_child(self):
        """Gracefully terminates child process with escalation to SIGKILL."""
        if not self.child_process or self.child_process.poll() is not None:
            return

        pid = self.child_process.pid
        self.log("WARN", f"Terminating child process PID {pid} (SIGTERM)...")
        try:
            if hasattr(os, "killpg") and hasattr(os, "getpgid"):
                os.killpg(os.getpgid(pid), signal.SIGTERM)
            else:
                self.child_process.terminate()
        except OSError:
            pass

        # Wait up to 3 seconds for graceful shutdown
        for _ in range(6):
            if self.child_process.poll() is not None:
                self.log("INFO", f"Process PID {pid} terminated cleanly.")
                return
            time.sleep(0.5)

        # Escalate to SIGKILL
        self.log("ERROR", f"Process PID {pid} did not terminate. Escalating to SIGKILL!")
        try:
            if hasattr(os, "killpg") and hasattr(os, "getpgid"):
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            else:
                self.child_process.kill()
        except OSError:
            pass

    def handle_failure(self, reason: str):
        self.log("ERROR", f"Service failure detected: {reason}")
        self.last_error = reason

        # Record restart timestamp
        now = time.time()
        self.restart_timestamps.append(now)
        self.total_restarts += 1

        recent_restarts = self.get_recent_restart_count()
        self.log("WARN", f"Restarts in current window: {recent_restarts}/{self.max_restarts} (Total: {self.total_restarts})")

        # Flapping protection check
        if recent_restarts > self.max_restarts:
            self.state = "FLAPPING"
            alert_msg = (
                f"CRITICAL: Flapping detected! Service exceeded restart rate limit "
                f"({recent_restarts} restarts in {self.window_seconds}s). Pausing restarts."
            )
            self.log("CRITICAL", alert_msg)
            self.send_webhook_alert("FLAPPING_DETECTED", {"recent_restarts": recent_restarts, "reason": reason})
            self.kill_child()
            self.update_status_file()
            return

        self.state = "RESTARTING"
        self.send_webhook_alert("SERVICE_RESTARTING", {"recent_restarts": recent_restarts, "reason": reason})
        self.kill_child()
        time.sleep(1.0)
        self.start_child()

    def run(self):
        global RUNNING
        self.log("INFO", "Process Watchdog Daemon started.")
        self.start_child()

        while RUNNING:
            time.sleep(self.check_interval)

            if not RUNNING:
                break

            if self.state == "FLAPPING":
                # In flapping state, check if cooling window has elapsed
                if self.get_recent_restart_count() <= self.max_restarts:
                    self.log("INFO", "Flapping window cooled down. Attempting recovery restart...")
                    self.start_child()
                else:
                    self.update_status_file()
                    continue

            # 1. Perform L1 PID check
            if not self.check_l1_pid():
                exit_code = self.child_process.poll() if self.child_process else "Unknown"
                self.handle_failure(f"Process terminated unexpectedly with exit code {exit_code}")
                continue

            # 2. Perform L7 HTTP check
            if self.http_check_url:
                if not self.check_l7_http():
                    self.consecutive_failures += 1
                    self.log("WARN", f"Health probe failed ({self.consecutive_failures}/2): {self.last_error}")
                    if self.consecutive_failures >= 2:
                        self.handle_failure("Unresponsive service (L7 HTTP probe timeout/failure)")
                        continue
                else:
                    self.consecutive_failures = 0
                    if self.state != "HEALTHY":
                        self.state = "HEALTHY"
                        self.log("INFO", f"Service is HEALTHY (PID {self.child_process.pid}, probe passed).")
            else:
                if self.state != "HEALTHY":
                    self.state = "HEALTHY"
                    self.log("INFO", f"Service is HEALTHY (PID {self.child_process.pid}).")

            self.update_status_file()

        self.cleanup()

    def cleanup(self):
        self.state = "STOPPED"
        self.log("INFO", "Watchdog shutting down. Stopping supervised child process...")
        self.kill_child()
        self.update_status_file()
        if os.path.exists(WATCHDOG_PID_FILE):
            try:
                os.remove(WATCHDOG_PID_FILE)
            except OSError:
                pass
        self.log("INFO", "Watchdog shutdown complete.")


def signal_handler(signum, frame):
    global RUNNING
    print(f"\n[Watchdog] Caught signal {signum}. Initiating shutdown...", flush=True)
    RUNNING = False


def print_status():
    if not os.path.exists(STATUS_FILE_PATH):
        print(json.dumps({"status": "STOPPED", "message": "Watchdog is not running or no status file found."}, indent=2))
        return 0

    try:
        with open(STATUS_FILE_PATH, "r") as f:
            data = json.load(f)
            print(json.dumps(data, indent=2))
            return 0
    except Exception as e:
        print(json.dumps({"error": f"Failed to read status: {e}"}), file=sys.stderr)
        return 1


def stop_daemon():
    if not os.path.exists(WATCHDOG_PID_FILE):
        print("[Watchdog] No watchdog.pid found. Attempting to kill by status file...")
        if os.path.exists(STATUS_FILE_PATH):
            try:
                with open(STATUS_FILE_PATH, "r") as f:
                    data = json.load(f)
                    w_pid = data.get("watchdog_pid")
                    if w_pid:
                        os.kill(w_pid, signal.SIGTERM)
                        print(f"[Watchdog] Sent SIGTERM to Watchdog PID {w_pid}")
                        return 0
            except Exception:
                pass
        print("[Watchdog] Watchdog does not appear to be running.")
        return 0

    try:
        with open(WATCHDOG_PID_FILE, "r") as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
        print(f"[Watchdog] Sent SIGTERM to Watchdog PID {pid}.")
        return 0
    except Exception as e:
        print(f"[Watchdog] Error stopping daemon: {e}", file=sys.stderr)
        return 1


def main():
    parser = argparse.ArgumentParser(description="Process Watchdog & Supervisor Daemon")
    parser.add_argument("--command", default="python3 flaky_service.py", help="Command to supervise (default: python3 flaky_service.py)")
    parser.add_argument("--http-check", default=None, help="HTTP healthcheck URL probe (e.g. http://127.0.0.1:8080/healthz)")
    parser.add_argument("--interval", type=float, default=2.0, help="Healthcheck polling interval in seconds (default: 2.0)")
    parser.add_argument("--max-restarts", type=int, default=3, help="Max restarts permitted in window before flapping (default: 3)")
    parser.add_argument("--window", type=int, default=60, help="Sliding time window for flapping detection in seconds (default: 60)")
    parser.add_argument("--timeout", type=float, default=2.0, help="HTTP health probe timeout in seconds (default: 2.0)")
    parser.add_argument("--webhook-url", default=None, help="Webhook URL for alert notifications")
    parser.add_argument("--status", action="store_true", help="Print current status JSON and exit")
    parser.add_argument("--stop", action="store_true", help="Stop running watchdog daemon")

    args = parser.parse_args()

    if args.status:
        sys.exit(print_status())

    if args.stop:
        sys.exit(stop_daemon())

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Write Watchdog PID
    with open(WATCHDOG_PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    supervisor = ProcessSupervisor(
        command=args.command,
        http_check_url=args.http_check,
        check_interval=args.interval,
        max_restarts=args.max_restarts,
        window_seconds=args.window,
        http_timeout=args.timeout,
        webhook_url=args.webhook_url
    )

    supervisor.run()


if __name__ == "__main__":
    main()
