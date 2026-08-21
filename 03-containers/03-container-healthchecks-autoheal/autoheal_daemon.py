#!/usr/bin/env python3
"""
Container Autoheal Engine & Docker Socket Watcher
=================================================
Monitors Docker engine events over the Unix domain socket (/var/run/docker.sock).
When a container transitions to an UNHEALTHY state, the daemon detects the event
and initiates an automated graceful restart to recover the workload.
"""

import argparse
import http.client
import json
import logging
import os
import signal
import socket
import sys
import time
import urllib.parse
from datetime import datetime

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"

# Logger Configuration
logging.basicConfig(
    level=logging.INFO,
    format=f"{CLR_GRAY}%(asctime)s{CLR_RESET} [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("autoheal-daemon")


class UnixSocketHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection implementation for Unix Domain Sockets."""

    def __init__(self, socket_path, timeout=30):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if self.timeout is not None:
            self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


class DockerSocketClient:
    """Zero-dependency Docker Engine REST API client communicating over Unix socket."""

    def __init__(self, socket_path="/var/run/docker.sock"):
        self.socket_path = socket_path
        if not os.path.exists(socket_path):
            raise FileNotFoundError(f"Docker socket not found at '{socket_path}'. Ensure Docker daemon is active.")

    def request(self, method, path, body=None, headers=None, timeout=10):
        conn = UnixSocketHTTPConnection(self.socket_path, timeout=timeout)
        try:
            req_headers = headers or {}
            if body and "Content-Type" not in req_headers:
                req_headers["Content-Type"] = "application/json"
            
            conn.request(method, path, body=body, headers=req_headers)
            response = conn.getresponse()
            res_data = response.read().decode("utf-8")
            return response.status, res_data
        finally:
            conn.close()

    def ping(self):
        """Verify Docker daemon responsiveness."""
        status, data = self.request("GET", "/_ping", timeout=3)
        return status == 200 and data.strip() == "OK"

    def list_unhealthy_containers(self):
        """Query currently active containers that have state=unhealthy."""
        filters = urllib.parse.quote(json.dumps({"health": ["unhealthy"]}))
        status, data = self.request("GET", f"/containers/json?filters={filters}")
        if status == 200:
            return json.loads(data)
        return []

    def inspect_container(self, container_id):
        """Fetch detailed container inspection metadata."""
        status, data = self.request("GET", f"/containers/{container_id}/json")
        if status == 200:
            return json.loads(data)
        return None

    def restart_container(self, container_id, timeout_seconds=5):
        """Trigger graceful container restart."""
        status, _ = self.request("POST", f"/containers/{container_id}/restart?t={timeout_seconds}", timeout=timeout_seconds + 5)
        return status in (200, 204)

    def stream_events(self):
        """Establish continuous streaming connection for container health events."""
        filters = urllib.parse.quote(json.dumps({
            "type": ["container"],
        }))
        conn = UnixSocketHTTPConnection(self.socket_path, timeout=None)
        conn.request("GET", f"/events?filters={filters}")
        response = conn.getresponse()

        if response.status != 200:
            raise RuntimeError(f"Failed to stream events from Docker socket. HTTP Status: {response.status}")

        while True:
            line = response.fp.readline()
            if not line:
                break
            line_str = line.decode("utf-8").strip()
            if not line_str:
                continue
            try:
                event = json.loads(line_str)
                yield event
            except json.JSONDecodeError:
                continue


class AutohealEngine:
    """Core daemon managing health state, cooldown rate-limiting, and auto-healing."""

    def __init__(self, socket_path="/var/run/docker.sock", cooldown_seconds=10, dry_run=False):
        self.client = DockerSocketClient(socket_path)
        self.cooldown_seconds = cooldown_seconds
        self.dry_run = dry_run
        self.restart_history = {}  # {container_id: last_restart_timestamp}
        self.running = True
        self.stats = {
            "start_time": time.time(),
            "unhealthy_events_detected": 0,
            "containers_healed": 0,
            "cooldown_throttles": 0,
        }

    def heal_container(self, container_id, container_name, reason="Healthcheck failure"):
        """Evaluate container restart against cooldown policy and execute recovery."""
        now = time.time()
        last_restart = self.restart_history.get(container_id, 0)
        time_since_restart = now - last_restart

        if time_since_restart < self.cooldown_seconds:
            remaining = round(self.cooldown_seconds - time_since_restart, 1)
            logger.warning(
                f"{CLR_YELLOW}⏳ Cooldown active for {CLR_BOLD}{container_name}{CLR_RESET} "
                f"(Restarted {round(time_since_restart, 1)}s ago). Skipping for {remaining}s."
            )
            self.stats["cooldown_throttles"] += 1
            return False

        logger.info(
            f"{CLR_RED}🚨 UNHEALTHY CONTAINER DETECTED:{CLR_RESET} {CLR_BOLD}{container_name}{CLR_RESET} "
            f"(ID: {container_id[:12]}) - Reason: {reason}"
        )

        if self.dry_run:
            logger.info(f"{CLR_YELLOW}[DRY-RUN]{CLR_RESET} Would initiate graceful restart for {container_name}")
            return True

        logger.info(f"{CLR_CYAN}⚡ [AUTO-HEAL]{CLR_RESET} Initiating graceful restart for {CLR_BOLD}{container_name}{CLR_RESET}...")
        success = self.client.restart_container(container_id, timeout_seconds=5)

        if success:
            self.restart_history[container_id] = time.time()
            self.stats["containers_healed"] += 1
            logger.info(
                f"{CLR_GREEN}✔ [RECOVERED]{CLR_RESET} Container {CLR_BOLD}{container_name}{CLR_RESET} "
                f"restarted successfully! Probing initial health..."
            )
            return True
        else:
            logger.error(f"{CLR_RED}✘ [FAILED]{CLR_RESET} Failed to trigger restart for {container_name}")
            return False

    def scan_and_heal_once(self):
        """Single polling cycle inspecting active unhealthy containers."""
        unhealthy_containers = self.client.list_unhealthy_containers()
        healed_count = 0

        for item in unhealthy_containers:
            cid = item.get("Id", "")
            names = item.get("Names", ["unknown"])
            name = names[0].lstrip("/") if names else cid[:12]
            
            self.stats["unhealthy_events_detected"] += 1
            if self.heal_container(cid, name, reason="Polling state assertion"):
                healed_count += 1

        return healed_count

    def run_daemon(self):
        """Run continuous autoheal watcher combining real-time events and polling backup."""
        import threading

        logger.info(f"{CLR_CYAN}{CLR_BOLD}===================================================================={CLR_RESET}")
        logger.info(f"  🩺 {CLR_BOLD}DOCKER CONTAINER AUTOHEAL ENGINE ACTIVE{CLR_RESET}")
        logger.info(f"{CLR_CYAN}{CLR_BOLD}===================================================================={CLR_RESET}")
        logger.info(f"Socket Path:    {self.client.socket_path}")
        logger.info(f"Cooldown Period: {self.cooldown_seconds}s")
        logger.info(f"Dry-Run Mode:    {'ENABLED' if self.dry_run else 'DISABLED'}")
        logger.info(f"Watching Docker socket for '{CLR_RED}health_status: unhealthy{CLR_RESET}' events...\n")

        # Initial sweep
        self.scan_and_heal_once()

        # Background polling thread for ultra-reliable backup assertion
        def poller_thread():
            while self.running:
                try:
                    self.scan_and_heal_once()
                except Exception:
                    pass
                time.sleep(2)

        poller = threading.Thread(target=poller_thread, daemon=True)
        poller.start()

        while self.running:
            try:
                for event in self.client.stream_events():
                    action = event.get("Action", event.get("status", ""))
                    actor = event.get("Actor", {})
                    attributes = actor.get("Attributes", {})
                    cid = actor.get("ID", event.get("id", ""))
                    name = attributes.get("name", cid[:12])
                    health_status = attributes.get("health_status", "")

                    if "unhealthy" in action or health_status == "unhealthy":
                        self.stats["unhealthy_events_detected"] += 1
                        self.heal_container(cid, name, reason=f"Event stream ({action})")
                    elif "healthy" in action or health_status == "healthy":
                        logger.info(f"{CLR_GREEN}✨ Container {CLR_BOLD}{name}{CLR_RESET} is now HEALTHY.{CLR_RESET}")

            except (socket.timeout, http.client.RemoteDisconnected, ConnectionResetError) as e:
                logger.warning(f"Event stream disconnected ({e}). Reconnecting in 2s...")
                time.sleep(2)
            except Exception as e:
                logger.error(f"Unexpected stream error: {e}. Reconnecting in 3s...")
                time.sleep(3)


def main():
    parser = argparse.ArgumentParser(
        description="Automated Docker Container Health Monitor & Autoheal Engine",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--socket",
        default=os.getenv("DOCKER_SOCKET", "/var/run/docker.sock"),
        help="Path to Docker Unix domain socket (default: /var/run/docker.sock)",
    )
    parser.add_argument(
        "--cooldown",
        type=int,
        default=int(os.getenv("AUTOHEAL_COOLDOWN", "10")),
        help="Minimum seconds between restarts of the same container (default: 10)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Detect unhealthy containers without issuing restart commands",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Perform a single inspection sweep and exit",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output detected unhealthy containers as JSON",
    )

    args = parser.parse_args()

    try:
        engine = AutohealEngine(
            socket_path=args.socket,
            cooldown_seconds=args.cooldown,
            dry_run=args.dry_run,
        )
    except FileNotFoundError as e:
        logger.error(str(e))
        sys.exit(1)

    if not engine.client.ping():
        logger.error("Failed to communicate with Docker daemon over socket.")
        sys.exit(1)

    # Graceful shutdown handler
    def signal_handler(signum, frame):
        logger.info("\nStopping Autoheal Daemon. Summary: %d healed.", engine.stats["containers_healed"])
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    if args.json:
        unhealthy = engine.client.list_unhealthy_containers()
        print(json.dumps({
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "unhealthy_count": len(unhealthy),
            "containers": [
                {
                    "id": c.get("Id", "")[:12],
                    "name": c.get("Names", [""])[0].lstrip("/"),
                    "image": c.get("Image", ""),
                    "state": c.get("State", ""),
                    "status": c.get("Status", ""),
                }
                for c in unhealthy
            ],
        }, indent=2))
        sys.exit(0)

    if args.once:
        count = engine.scan_and_heal_once()
        logger.info(f"Sweep complete. Inspected and processed {count} unhealthy containers.")
        sys.exit(0)

    engine.run_daemon()


if __name__ == "__main__":
    main()
