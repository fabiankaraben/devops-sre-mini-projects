#!/usr/bin/env python3
"""Synthetic PII Log Generator for Vector Sanitization Pipeline.

Emits structured JSON and unstructured application logs containing realistic Personally
Identifiable Information (PII) including Credit Card numbers (Visa, MasterCard, Amex, Discover),
Social Security Numbers (SSNs), Passwords, API Keys, JWT Tokens, Emails, and Phone Numbers.
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
from typing import Any, Dict, List, Optional, Tuple

# Terminal Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"

FIRST_NAMES = ["Alice", "Bob", "Carlos", "Diana", "Evan", "Fiona", "George", "Hannah", "Ivan", "Julia"]
LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez"]
DOMAINS = ["gmail.com", "yahoo.com", "outlook.com", "acme-corp.com", "fintech.io", "enterprise.net"]
SERVICES = ["checkout-service", "auth-gateway", "billing-daemon", "loan-evaluator", "kyc-processor", "user-mgmt"]
CURRENCIES = ["USD", "EUR", "GBP", "CAD", "AUD"]
HTTP_METHODS = ["GET", "POST", "PUT", "DELETE"]


def generate_credit_card(brand: Optional[str] = None) -> Tuple[str, str, str]:
    """Generate a realistic credit card number, brand, and CVV code."""
    if brand is None:
        brand = random.choice(["Visa", "MasterCard", "Amex", "Discover"])

    if brand == "Visa":
        num = "4" + "".join([str(random.randint(0, 9)) for _ in range(15)])
        cvv = f"{random.randint(100, 999)}"
        formatted = f"{num[:4]}-{num[4:8]}-{num[8:12]}-{num[12:]}" if random.random() < 0.7 else num
    elif brand == "MasterCard":
        num = f"5{random.randint(1, 5)}" + "".join([str(random.randint(0, 9)) for _ in range(14)])
        cvv = f"{random.randint(100, 999)}"
        formatted = f"{num[:4]} {num[4:8]} {num[8:12]} {num[12:]}" if random.random() < 0.7 else num
    elif brand == "Amex":
        num = f"3{random.choice(['4', '7'])}" + "".join([str(random.randint(0, 9)) for _ in range(13)])
        cvv = f"{random.randint(1000, 9999)}"
        formatted = f"{num[:4]}-{num[4:10]}-{num[10:]}" if random.random() < 0.7 else num
    else:  # Discover
        num = "6011" + "".join([str(random.randint(0, 9)) for _ in range(12)])
        cvv = f"{random.randint(100, 999)}"
        formatted = f"{num[:4]}-{num[4:8]}-{num[8:12]}-{num[12:]}" if random.random() < 0.7 else num

    return formatted, brand, cvv


def generate_ssn() -> str:
    """Generate a US Social Security Number in standard format xxx-xx-xxxx."""
    area = random.randint(100, 899)
    group = random.randint(10, 99)
    serial = random.randint(1000, 9999)
    return f"{area:03d}-{group:02d}-{serial:04d}"


def generate_email(first: str, last: str) -> str:
    """Generate an email address."""
    domain = random.choice(DOMAINS)
    pattern = random.choice([
        f"{first.lower()}.{last.lower()}@{domain}",
        f"{first.lower()[0]}{last.lower()}{random.randint(10, 99)}@{domain}",
        f"{first.lower()}_{last.lower()}@{domain}",
    ])
    return pattern


def generate_phone() -> str:
    """Generate a phone number in standard formats."""
    area = random.randint(200, 999)
    prefix = random.randint(200, 999)
    line = random.randint(1000, 9999)
    format_choice = random.random()
    if format_choice < 0.4:
        return f"+1 ({area}) {prefix}-{line}"
    elif format_choice < 0.7:
        return f"{area}-{prefix}-{line}"
    else:
        return f"({area}) {prefix}-{line}"


def generate_password() -> str:
    """Generate a realistic password with symbols and numbers."""
    words = ["Summer", "Winter", "Spring", "Autumn", "Matrix", "Cipher", "Phoenix", "Rocket", "Falcon", "Secure"]
    symbols = ["!", "@", "#", "$", "%", "*"]
    return f"{random.choice(words)}{random.randint(100, 9999)}{random.choice(symbols)}"


def generate_jwt() -> str:
    """Generate a mock 3-part Bearer JWT token."""
    header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    payload = f"eyJzdWIiOiJ1c3Jfe3JhbmRvbS5yYW5kaW50KDEwMCwgOTk5KX0iLCJyb2xlIjoiYWRtaW4ifQ"
    sig = f"sig_{random.randint(10000000, 99999999):08x}abcdef123456"
    return f"{header}.{payload}.{sig}"


def generate_api_key() -> str:
    """Generate a mock SaaS API Secret key."""
    prefix = random.choice(["sk_live", "sk_test", "whsec", "ghp", "sec_key"])
    token = "".join(random.choices("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", k=32))
    return f"{prefix}_{token}"


def generate_structured_json_log(event_num: int) -> Dict[str, Any]:
    """Generate a structured JSON log containing sensitive PII fields."""
    first = random.choice(FIRST_NAMES)
    last = random.choice(LAST_NAMES)
    email = generate_email(first, last)
    card_num, brand, cvv = generate_credit_card()
    ssn = generate_ssn()
    phone = generate_phone()
    
    event_types = ["checkout", "user_registration", "auth_login", "loan_application", "api_integration"]
    event_type = random.choice(event_types)

    base = {
        "event_id": f"evt-{event_num:06d}",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "service": random.choice(SERVICES),
        "user_id": f"usr_{random.randint(100, 999)}",
        "ip_address": f"{random.randint(11, 220)}.{random.randint(1, 250)}.{random.randint(1, 250)}.{random.randint(1, 250)}",
        "action": event_type,
    }

    if event_type == "checkout":
        base.update({
            "amount": round(random.uniform(5.0, 2500.0), 2),
            "currency": random.choice(CURRENCIES),
            "card_brand": brand,
            "credit_card": card_num,
            "cvv": cvv,
            "billing_email": email,
        })
    elif event_type == "user_registration":
        base.update({
            "first_name": first,
            "last_name": last,
            "email": email,
            "ssn": ssn,
            "phone": phone,
            "password": generate_password(),
            "password_confirmation": generate_password(),
        })
    elif event_type == "auth_login":
        base.update({
            "username": email,
            "password": generate_password(),
            "authorization": f"Bearer {generate_jwt()}",
            "access_token": generate_api_key(),
            "status_code": random.choice([200, 201, 401, 403]),
        })
    elif event_type == "loan_application":
        base.update({
            "applicant_name": f"{first} {last}",
            "ssn": ssn,
            "phone_number": phone,
            "annual_income": random.randint(45000, 250000),
            "card_number": card_num,
            "security_code": cvv,
        })
    else:  # api_integration
        base.update({
            "api_key": generate_api_key(),
            "secret": generate_api_key(),
            "bearer_token": generate_jwt(),
            "endpoint": "/api/v1/stripe/webhook",
        })

    return base


def generate_unstructured_string_log(event_num: int) -> str:
    """Generate an unstructured text log string with embedded PII."""
    first = random.choice(FIRST_NAMES)
    last = random.choice(LAST_NAMES)
    email = generate_email(first, last)
    card_num, brand, cvv = generate_credit_card()
    ssn = generate_ssn()
    phone = generate_phone()
    pw = generate_password()
    jwt = generate_jwt()
    api_key = generate_api_key()
    service = random.choice(SERVICES)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    templates = [
        f"{ts} [INFO] [{service}] Processed payment order #{event_num} for user {email}: card={card_num} cvv={cvv} amount=${random.randint(10, 500)}",
        f"{ts} [WARN] [{service}] Identity verification retry for SSN {ssn} (Name: {first} {last}, phone: {phone}, email: {email})",
        f"{ts} [ERROR] [{service}] Authentication failed for user={email} with password={pw} from IP 192.168.1.55",
        f"{ts} [DEBUG] [{service}] Outbound payment gateway request token={jwt} api_key={api_key} card_number={card_num}",
        f"{ts} [INFO] [{service}] Customer support callback requested at {phone} for account SSN {ssn}",
    ]
    return random.choice(templates)


class VectorStreamer:
    """Sends log records to Vector over HTTP REST or TCP Socket."""

    def __init__(self, host: str = "127.0.0.1", http_port: int = 8080, tcp_port: int = 9000):
        self.host = host
        self.http_port = http_port
        self.tcp_port = tcp_port

    def send_http(self, payload_lines: List[str], rate: float = 0.0) -> int:
        """Post log records to Vector HTTP source."""
        url = f"http://{self.host}:{self.http_port}"
        print(f"  Streaming {len(payload_lines)} records to Vector HTTP endpoint {url}...")
        sent = 0
        delay = 1.0 / rate if rate > 0 else 0.0
        start_time = time.perf_counter()

        for line in payload_lines:
            body = line.encode("utf-8")
            req = urllib.request.Request(
                url,
                data=body,
                headers={"Content-Type": "application/json", "User-Agent": "PII-Generator/1.0"},
                method="POST"
            )
            success = False
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=5.0) as resp:
                        if resp.status in (200, 201, 202, 204):
                            sent += 1
                            success = True
                            break
                except Exception as exc:
                    if attempt < 2:
                        time.sleep(0.2)
                    else:
                        print(f"  [{CLR_RED}ERROR{CLR_RESET}] HTTP send error on record #{sent + 1}: {exc}")
            if not success:
                break
            if delay > 0:
                time.sleep(delay)

        elapsed = time.perf_counter() - start_time
        rps = sent / elapsed if elapsed > 0 else 0
        print(f"  [{CLR_GREEN}SUCCESS{CLR_RESET}] Dispatched {sent} records via HTTP in {elapsed:.2f}s ({rps:.1f} req/sec).")
        return sent

    def send_tcp(self, payload_lines: List[str], rate: float = 0.0) -> int:
        """Stream log records to Vector TCP socket source."""
        print(f"  Connecting to Vector TCP endpoint {self.host}:{self.tcp_port}...")
        sent = 0
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.settimeout(10.0)
                sock.connect((self.host, self.tcp_port))
                print(f"  [{CLR_GREEN}CONNECTED{CLR_RESET}] Streaming raw records over TCP...")
                
                delay = 1.0 / rate if rate > 0 else 0.0
                start_time = time.perf_counter()

                for line in payload_lines:
                    data = (line.strip() + "\n").encode("utf-8")
                    sock.sendall(data)
                    sent += 1
                    if delay > 0:
                        time.sleep(delay)
                    elif sent % 100 == 0:
                        time.sleep(0.001)

                elapsed = time.perf_counter() - start_time
                rps = sent / elapsed if elapsed > 0 else 0
                print(f"  [{CLR_GREEN}SUCCESS{CLR_RESET}] Streamed {sent} records via TCP in {elapsed:.2f}s ({rps:.1f} lines/sec).")
                return sent
        except ConnectionRefusedError:
            print(f"  [{CLR_RED}ERROR{CLR_RESET}] Connection refused at {self.host}:{self.tcp_port}. Is Vector running?")
            return 0
        except Exception as exc:
            print(f"  [{CLR_RED}ERROR{CLR_RESET}] TCP streaming error: {exc}")
            return sent


def generate_mixed_batch(count: int = 100) -> List[str]:
    """Generate a balanced mix of structured JSON and unstructured text records with PII."""
    records = []
    for i in range(1, count + 1):
        if random.random() < 0.75:
            records.append(json.dumps(generate_structured_json_log(i)))
        else:
            records.append(generate_unstructured_string_log(i))
    return records


def main():
    parser = argparse.ArgumentParser(
        description="Emit synthetic or fixture logs with sensitive PII to Vector sanitization pipeline."
    )
    parser.add_argument(
        "--protocol",
        choices=["http", "tcp", "stdout"],
        default="http",
        help="Delivery transport (default: http)",
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Vector host (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--http-port",
        type=int,
        default=8080,
        help="Vector HTTP port (default: 8080)",
    )
    parser.add_argument(
        "--tcp-port",
        type=int,
        default=9000,
        help="Vector TCP port (default: 9000)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=100,
        help="Number of log records to generate (default: 100)",
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=0.0,
        help="Rate limit in lines/sec (0 = unthrottled burst)",
    )
    parser.add_argument(
        "--sample-file",
        type=str,
        default=None,
        help="Stream logs from an existing fixture file",
    )
    parser.add_argument(
        "--output-file",
        type=str,
        default=None,
        help="Save generated records to a local file",
    )
    parser.add_argument(
        "--continuous",
        action="store_true",
        help="Stream continuously in an infinite loop",
    )

    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🛡️  Vector PII Log Generator & Streaming Client{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

    streamer = VectorStreamer(host=args.host, http_port=args.http_port, tcp_port=args.tcp_port)

    if args.sample_file:
        file_path = Path(args.sample_file)
        if not file_path.exists():
            print(f"{CLR_RED}Error: Sample file {args.sample_file} not found.{CLR_RESET}")
            sys.exit(1)
        with open(file_path, "r", encoding="utf-8") as f:
            lines = [l.strip() for l in f if l.strip()]
        print(f"  Loaded {len(lines)} records from {args.sample_file}.")
    else:
        lines = generate_mixed_batch(count=args.count)
        print(f"  Generated {len(lines)} synthetic PII records (Credit Cards, SSNs, Passwords, Emails, JWTs).")

    if args.output_file:
        out_path = Path(args.output_file)
        with open(out_path, "w", encoding="utf-8") as f:
            for line in lines:
                f.write(line + "\n")
        print(f"  Saved records to {out_path}.")

    if args.protocol == "stdout":
        print(f"\n{CLR_YELLOW}--- Log Output Preview ({len(lines)} records) ---{CLR_RESET}")
        for line in lines:
            print(line)
        sys.exit(0)

    if args.continuous:
        print(f"{CLR_YELLOW}Starting continuous streaming mode (Press Ctrl+C to exit)...{CLR_RESET}")
        rate = args.rate if args.rate > 0 else 10.0
        total = 0
        try:
            while True:
                batch = generate_mixed_batch(count=int(rate * 2))
                if args.protocol == "http":
                    sent = streamer.send_http(batch, rate=rate)
                else:
                    sent = streamer.send_tcp(batch, rate=rate)
                total += sent
                time.sleep(1.0)
        except KeyboardInterrupt:
            print(f"\n{CLR_GREEN}Continuous streaming stopped. Total sent: {total}{CLR_RESET}")
            sys.exit(0)
    else:
        if args.protocol == "http":
            sent = streamer.send_http(lines, rate=args.rate)
        else:
            sent = streamer.send_tcp(lines, rate=args.rate)

        if sent == 0:
            print(f"{CLR_RED}Failed to dispatch records.{CLR_RESET}")
            sys.exit(1)
        else:
            print(f"{CLR_GREEN}Successfully forwarded {sent} PII records to Vector!{CLR_RESET}\n")


if __name__ == "__main__":
    main()
