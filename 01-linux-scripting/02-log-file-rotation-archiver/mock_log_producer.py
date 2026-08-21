#!/usr/bin/env python3
"""
mock_log_producer.py - Continuous Log Producer & File Descriptor Daemon

Simulates an active production web service generating real-time logs.
Maintains an open file descriptor, flushes buffers, and dynamically responds
to SIGHUP/SIGUSR1 signals for testing non-destructive log rotation.
"""

import argparse
import datetime
import json
import os
import random
import signal
import sys
import time

# Global state
running = True
log_file_handle = None
current_log_path = ""
reopen_requested = False


def signal_handler(signum, frame):
    global running, reopen_requested
    if signum in (signal.SIGTERM, signal.SIGINT):
        print(f"\n[mock_log_producer] Caught signal {signum}. Shutting down gracefully...", flush=True)
        running = False
    elif signum in (signal.SIGUSR1, signal.SIGHUP):
        print(f"[mock_log_producer] Caught signal {signum} (Reopen Request). Flagging file descriptor reopen.", flush=True)
        reopen_requested = True


def open_log_file(path: str):
    """Opens log file in append mode and ensures parent directories exist."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    f = open(path, "a", encoding="utf-8")
    print(f"[mock_log_producer] Opened '{path}' on File Descriptor {f.fileno()}", flush=True)
    return f


def generate_log_entry(fmt: str) -> str:
    """Generates a realistic mock log entry in JSON or Combined Text format."""
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    endpoints = ["/api/v1/users", "/api/v1/products", "/healthz", "/login", "/checkout", "/metrics"]
    statuses = [200, 200, 200, 201, 400, 404, 500]
    methods = ["GET", "POST", "PUT", "DELETE"]
    ip_addrs = ["192.168.1.10", "10.0.0.42", "172.16.2.100", "127.0.0.1"]

    method = random.choice(methods)
    endpoint = random.choice(endpoints)
    status = random.choice(statuses)
    latency_ms = round(random.uniform(2.5, 120.0), 2)
    client_ip = random.choice(ip_addrs)

    if fmt == "json":
        data = {
            "timestamp": now,
            "level": "INFO" if status < 400 else ("WARN" if status < 500 else "ERROR"),
            "client_ip": client_ip,
            "method": method,
            "endpoint": endpoint,
            "status": status,
            "latency_ms": latency_ms,
            "pid": os.getpid()
        }
        return json.dumps(data)
    else:
        # Standard Apache/Nginx Combined Log Format simulation
        return f'{client_ip} - - [{now}] "{method} {endpoint} HTTP/1.1" {status} {random.randint(200, 4096)} {latency_ms}ms'


def main():
    global running, log_file_handle, current_log_path, reopen_requested

    parser = argparse.ArgumentParser(
        description="Mock Log Producer Daemon for testing log rotation."
    )
    parser.add_argument(
        "--log-file",
        default="./logs/app.log",
        help="Destination path for log file (default: ./logs/app.log)"
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=5.0,
        help="Log generation rate in entries per second (default: 5.0)"
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=0,
        help="Duration to run in seconds (0 = run indefinitely, default: 0)"
    )
    parser.add_argument(
        "--format",
        choices=["json", "text"],
        default="json",
        help="Log entry format: json or text (default: json)"
    )

    args = parser.parse_args()
    current_log_path = args.log_file

    # Register POSIX signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGUSR1, signal_handler)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, signal_handler)

    print("=" * 55)
    print("  Mock Log Producer Daemon (DevOps / SRE Mini-Project)")
    print("=" * 55)
    print(f"PID         : {os.getpid()}")
    print(f"Log File    : {os.path.abspath(args.log_file)}")
    print(f"Format      : {args.format}")
    print(f"Rate        : {args.rate} entries/second")
    print(f"Duration    : {'Infinite' if args.duration == 0 else f'{args.duration}s'}")
    print("=" * 55, flush=True)

    log_file_handle = open_log_file(current_log_path)
    interval = 1.0 / max(0.1, args.rate)
    start_time = time.time()
    count = 0

    try:
        while running:
            # Check if signal requested file descriptor reopening
            if reopen_requested:
                reopen_requested = False
                print("[mock_log_producer] Closing existing file handle...", flush=True)
                try:
                    log_file_handle.flush()
                    log_file_handle.close()
                except Exception as e:
                    print(f"[mock_log_producer] Error closing handle: {e}", flush=True)
                
                log_file_handle = open_log_file(current_log_path)
                print("[mock_log_producer] Reopened log file successfully.", flush=True)

            entry = generate_log_entry(args.format)
            log_file_handle.write(entry + "\n")
            log_file_handle.flush()
            count += 1

            if args.duration > 0 and (time.time() - start_time) >= args.duration:
                print(f"[mock_log_producer] Duration {args.duration}s elapsed.", flush=True)
                break

            time.sleep(interval)
    finally:
        if log_file_handle and not log_file_handle.closed:
            log_file_handle.flush()
            log_file_handle.close()
        print(f"[mock_log_producer] Stopped. Total entries written: {count}.", flush=True)


if __name__ == "__main__":
    main()
