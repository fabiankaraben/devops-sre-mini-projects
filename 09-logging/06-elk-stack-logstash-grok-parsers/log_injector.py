#!/usr/bin/env python3
"""Log Injector for ELK Stack with Logstash Grok Parsers.

Streams raw unstructured Apache access logs, Nginx extended access logs,
microservice application logs, and test fixtures to Logstash via TCP or HTTP.
"""

import argparse
import datetime
import json
import random
import socket
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import List, Optional, Tuple

# ANSI Colors for Terminal Output
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"

# Realistic GeoIP-Resolvable Public IP Addresses
PUBLIC_IPS = [
    ("8.8.8.8", "United States", "Mountain View"),
    ("1.1.1.1", "Australia", "Sydney"),
    ("185.199.108.153", "United States", "San Francisco"),
    ("140.82.121.4", "United States", "Seattle"),
    ("177.18.200.45", "Brazil", "Sao Paulo"),
    ("200.58.112.10", "Argentina", "Buenos Aires"),
    ("13.230.12.89", "Japan", "Tokyo"),
    ("151.101.65.140", "United States", "New York"),
    ("194.29.178.10", "Poland", "Warsaw"),
    ("139.130.4.5", "Australia", "Melbourne"),
    ("82.165.197.1", "Germany", "Frankfurt"),
    ("212.27.48.10", "France", "Paris"),
    ("103.21.244.0", "Singapore", "Singapore"),
    ("106.51.79.1", "India", "Bangalore"),
]

HTTP_METHODS = [
    ("GET", 0.65),
    ("POST", 0.20),
    ("PUT", 0.05),
    ("DELETE", 0.05),
    ("PATCH", 0.03),
    ("OPTIONS", 0.02),
]

ENDPOINTS = [
    ("/api/v1/products", 200, 4500),
    ("/api/v1/products/481", 200, 1200),
    ("/api/v1/cart", 200, 850),
    ("/api/v1/cart/items", 201, 1024),
    ("/api/v1/checkout", 200, 3100),
    ("/api/v1/auth/login", 200, 600),
    ("/api/v1/auth/logout", 204, 0),
    ("/api/v1/user/profile", 200, 940),
    ("/api/v1/search?q=docker", 200, 7800),
    ("/static/js/main.bundle.js", 200, 154200),
    ("/static/css/theme.css", 304, 0),
    ("/healthz", 200, 32),
    ("/metrics", 200, 1840),
    ("/admin/secrets", 403, 512),
    ("/api/v1/invalid-route", 404, 210),
    ("/api/v1/payment/process", 500, 1450),
    ("/api/v1/upstream/service", 502, 620),
    ("/api/v1/gateway/timeout", 504, 380),
]

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_3_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.6167.178 Mobile Safari/537.36",
    "Googlebot/2.1 (+http://www.google.com/bot.html)",
    "curl/8.4.0",
    "Prometheus/2.49.1",
]

REFERRERS = [
    "https://store.example.com/",
    "https://store.example.com/products",
    "https://store.example.com/cart",
    "https://www.google.com/",
    "https://github.com/",
    "-",
]

SERVICES = ["order-service", "auth-service", "billing-service", "inventory-service", "api-gateway"]
LOG_LEVELS = [("INFO", 0.70), ("WARN", 0.15), ("ERROR", 0.10), ("DEBUG", 0.05)]


def weighted_choice(choices_with_weights):
    """Select an item from a list of (item, weight) tuples."""
    items, weights = zip(*choices_with_weights)
    return random.choices(items, weights=weights, k=1)[0]


def format_apache_timestamp(dt: datetime.datetime) -> str:
    """Format datetime as Apache HTTP timestamp: [26/Aug/2026:10:15:30 +0000]."""
    return dt.strftime("%d/%b/%Y:%H:%M:%S +0000")


def format_iso_timestamp(dt: datetime.datetime) -> str:
    """Format datetime as ISO 8601 with millisecond precision."""
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def generate_apache_log(dt: Optional[datetime.datetime] = None) -> str:
    """Generate a realistic Apache Combined Access Log line."""
    if dt is None:
        dt = datetime.datetime.now(datetime.timezone.utc)
    
    ip_tuple = random.choice(PUBLIC_IPS)
    client_ip = ip_tuple[0]
    ident = "-"
    auth = "admin" if random.random() < 0.1 else "-"
    timestamp = format_apache_timestamp(dt)
    
    method = weighted_choice(HTTP_METHODS)
    endpoint, status, base_bytes = random.choice(ENDPOINTS)
    
    # Add random size jitter
    bytes_sent = base_bytes if status == 304 or status == 204 else max(45, int(base_bytes * random.uniform(0.8, 1.3)))
    
    referrer = random.choice(REFERRERS)
    user_agent = random.choice(USER_AGENTS)
    
    return f'{client_ip} {ident} {auth} [{timestamp}] "{method} {endpoint} HTTP/1.1" {status} {bytes_sent} "{referrer}" "{user_agent}"'


def generate_nginx_log(dt: Optional[datetime.datetime] = None) -> str:
    """Generate a realistic Nginx Extended Access Log line with latency."""
    if dt is None:
        dt = datetime.datetime.now(datetime.timezone.utc)
        
    ip_tuple = random.choice(PUBLIC_IPS)
    client_ip = ip_tuple[0]
    auth = "admin" if random.random() < 0.1 else "-"
    timestamp = format_apache_timestamp(dt)
    
    method = weighted_choice(HTTP_METHODS)
    endpoint, status, base_bytes = random.choice(ENDPOINTS)
    bytes_sent = base_bytes if status in (204, 304) else max(45, int(base_bytes * random.uniform(0.8, 1.3)))
    referrer = random.choice(REFERRERS)
    user_agent = random.choice(USER_AGENTS)
    
    # Request time latency in ms (fast for static, slower for dynamic / errors)
    if "/static/" in endpoint:
        latency = round(random.uniform(0.8, 15.0), 2)
    elif status >= 500:
        latency = round(random.uniform(800.0, 5000.0), 2)
    else:
        latency = round(random.uniform(10.0, 250.0), 2)
        
    return f'{client_ip} - {auth} [{timestamp}] "{method} {endpoint} HTTP/1.1" {status} {bytes_sent} "{referrer}" "{user_agent}" {latency}'


def generate_app_log(dt: Optional[datetime.datetime] = None) -> str:
    """Generate a realistic microservice application error/info log line."""
    if dt is None:
        dt = datetime.datetime.now(datetime.timezone.utc)
        
    timestamp = format_iso_timestamp(dt)
    level = weighted_choice(LOG_LEVELS)
    service = random.choice(SERVICES)
    trace_id = f"trace-{random.randint(100000, 999999):06x}"
    
    messages = {
        "INFO": [
            f"Successfully processed transaction for customer_id={random.randint(100, 999)}",
            f"User authentication verified for session_token=sess_{random.randint(1000, 9999)}",
            f"Cache refreshed for catalog category id={random.randint(1, 20)}",
        ],
        "WARN": [
            f"High memory consumption detected in buffer cache: {random.randint(75, 89)}% utilization",
            f"Slow database query execution: elapsed_time={random.randint(300, 900)}ms",
            f"Rate limit approaching threshold for tenant_id=org_{random.randint(10, 50)}",
        ],
        "ERROR": [
            f"Database connection timeout on query SELECT * FROM orders WHERE id={random.randint(1000, 9999)}",
            f"Failed to reach downstream payment webhook: HTTP 503 Service Unavailable",
            f"Unhandled NullPointerException during deserialization of order payload",
        ],
        "DEBUG": [
            f"Evaluating permission claims for scope 'orders:write'",
            f"Connection pool leased socket id=sock_{random.randint(1, 100)}",
        ],
    }
    
    msg = random.choice(messages[level])
    return f"{timestamp} [{level}] [{service}] [{trace_id}] {msg}"


def generate_malformed_log() -> str:
    """Generate an unparseable malformed log line to test _grokparsefailure."""
    corruptions = [
        "MALFORMED_UNSTRUCTURED_SYS_DUMP_0xCAFEBABE_FAULT",
        "!!! CORRUPT PACKET LINE HEADER NO MATCH !!!",
        "KERNEL: Out of memory: Kill process 4192 (mysqld) score 852",
    ]
    return random.choice(corruptions)


class LogStreamer:
    """Handles transmission of log lines over TCP socket or HTTP endpoint."""

    def __init__(self, host: str = "127.0.0.1", tcp_port: int = 50000, http_port: int = 8080):
        self.host = host
        self.tcp_port = tcp_port
        self.http_port = http_port

    def stream_tcp(self, log_lines: List[str], rate: float = 0.0) -> int:
        """Stream log lines over TCP socket with optional rate limiting."""
        print(f"  Connecting to TCP endpoint {self.host}:{self.tcp_port}...")
        sent_count = 0
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.settimeout(10.0)
                sock.connect((self.host, self.tcp_port))
                print(f"  [{CLR_GREEN}CONNECTED{CLR_RESET}] Streaming logs over TCP...")
                
                delay = 1.0 / rate if rate > 0 else 0.0
                start_time = time.perf_counter()

                for line in log_lines:
                    payload = (line.strip() + "\n").encode("utf-8")
                    sock.sendall(payload)
                    sent_count += 1

                    if delay > 0:
                        time.sleep(delay)
                    elif sent_count % 100 == 0:
                        # Slight yield to avoid saturating buffer
                        time.sleep(0.001)

                elapsed = time.perf_counter() - start_time
                rps = sent_count / elapsed if elapsed > 0 else 0
                print(f"  [{CLR_GREEN}SUCCESS{CLR_RESET}] Streamed {sent_count} log lines via TCP in {elapsed:.2f}s ({rps:.1f} lines/sec).")
                return sent_count
        except ConnectionRefusedError:
            print(f"  [{CLR_RED}ERROR{CLR_RESET}] TCP connection refused at {self.host}:{self.tcp_port}. Is Logstash running?")
            return 0
        except Exception as exc:
            print(f"  [{CLR_RED}ERROR{CLR_RESET}] TCP stream failure: {exc}")
            return sent_count

    def stream_http(self, log_lines: List[str], rate: float = 0.0) -> int:
        """Stream log lines via HTTP POST JSON messages with retry logic."""
        url = f"http://{self.host}:{self.http_port}"
        print(f"  Posting logs to HTTP endpoint {url}...")
        sent_count = 0
        delay = 1.0 / rate if rate > 0 else 0.0
        start_time = time.perf_counter()

        for line in log_lines:
            payload = json.dumps({"message": line.strip()}).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=payload,
                headers={"Content-Type": "application/json", "User-Agent": "LogInjector/1.0"},
                method="POST"
            )
            success = False
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=5.0) as resp:
                        if resp.status in (200, 201, 202):
                            sent_count += 1
                            success = True
                            break
                except Exception as exc:
                    if attempt < 2:
                        time.sleep(0.5)
                    else:
                        print(f"  [{CLR_RED}ERROR{CLR_RESET}] HTTP post error on record #{sent_count + 1}: {exc}")

            if not success:
                break

            if delay > 0:
                time.sleep(delay)

        elapsed = time.perf_counter() - start_time
        rps = sent_count / elapsed if elapsed > 0 else 0
        print(f"  [{CLR_GREEN}SUCCESS{CLR_RESET}] Posted {sent_count} log records via HTTP in {elapsed:.2f}s ({rps:.1f} req/sec).")
        return sent_count


def generate_log_batch(count: int = 100, include_malformed: bool = True) -> List[str]:
    """Generate a balanced batch of Apache, Nginx, App, and test logs."""
    logs = []
    base_time = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)

    for i in range(count):
        dt = base_time + datetime.timedelta(seconds=i * 2)
        choice = random.random()

        if include_malformed and choice < 0.05:
            logs.append(generate_malformed_log())
        elif choice < 0.45:
            logs.append(generate_apache_log(dt))
        elif choice < 0.80:
            logs.append(generate_nginx_log(dt))
        else:
            logs.append(generate_app_log(dt))

    return logs


def main():
    parser = argparse.ArgumentParser(
        description="Stream synthetic or fixture access logs to Logstash ELK pipeline."
    )
    parser.add_argument(
        "--protocol",
        choices=["tcp", "http", "stdout"],
        default="tcp",
        help="Transport protocol to send logs (default: tcp)",
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Logstash hostname or IP (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--tcp-port",
        type=int,
        default=50000,
        help="Logstash TCP input port (default: 50000)",
    )
    parser.add_argument(
        "--http-port",
        type=int,
        default=8080,
        help="Logstash HTTP input port (default: 8080)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=100,
        help="Number of synthetic log lines to generate and send (default: 100)",
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=0.0,
        help="Rate limit in lines/sec (0 = full speed burst, e.g. 20)",
    )
    parser.add_argument(
        "--sample-file",
        type=str,
        default=None,
        help="Stream logs from a specified file rather than generating synthetics",
    )
    parser.add_argument(
        "--output-file",
        type=str,
        default=None,
        help="Write generated synthetic logs to a local file in current dir",
    )
    parser.add_argument(
        "--continuous",
        action="store_true",
        help="Stream continuously in an infinite loop until interrupted (Ctrl+C)",
    )

    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  📡 ELK Logstash Grok Parser Log Injector{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

    streamer = LogStreamer(host=args.host, tcp_port=args.tcp_port, http_port=args.http_port)

    # Read from file or generate synthetic
    if args.sample_file:
        sample_path = Path(args.sample_file)
        if not sample_path.exists():
            print(f"{CLR_RED}Error: File {args.sample_file} not found.{CLR_RESET}")
            sys.exit(1)
        with open(sample_path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
        print(f"  Loaded {len(lines)} log lines from {args.sample_file}.")
    else:
        lines = generate_log_batch(count=args.count, include_malformed=True)
        print(f"  Generated {len(lines)} synthetic log records (Apache, Nginx, App & Edge cases).")

    # Optional local save
    if args.output_file:
        out_path = Path(args.output_file)
        with open(out_path, "w", encoding="utf-8") as f:
            for l in lines:
                f.write(l + "\n")
        print(f"  Saved generated logs to {out_path}.")

    # Output to stdout
    if args.protocol == "stdout":
        print(f"\n{CLR_YELLOW}--- Log Output Preview ({len(lines)} records) ---{CLR_RESET}")
        for line in lines:
            print(line)
        sys.exit(0)

    # Stream to Logstash
    if args.continuous:
        print(f"{CLR_YELLOW}Starting continuous streaming mode (Press Ctrl+C to stop)...{CLR_RESET}")
        rate = args.rate if args.rate > 0 else 10.0
        try:
            total_sent = 0
            while True:
                batch = generate_log_batch(count=int(rate * 2), include_malformed=True)
                if args.protocol == "tcp":
                    sent = streamer.stream_tcp(batch, rate=rate)
                else:
                    sent = streamer.stream_http(batch, rate=rate)
                total_sent += sent
                time.sleep(1.0)
        except KeyboardInterrupt:
            print(f"\n{CLR_GREEN}Continuous streaming stopped. Total records sent: {total_sent}{CLR_RESET}")
            sys.exit(0)
    else:
        if args.protocol == "tcp":
            sent = streamer.stream_tcp(lines, rate=args.rate)
        else:
            sent = streamer.stream_http(lines, rate=args.rate)

        if sent == 0:
            print(f"{CLR_RED}Failed to send log entries.{CLR_RESET}")
            sys.exit(1)
        else:
            print(f"{CLR_GREEN}Successfully dispatched {sent} log entries to Logstash!{CLR_RESET}\n")


if __name__ == "__main__":
    main()
