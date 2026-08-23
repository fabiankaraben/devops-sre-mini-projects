#!/usr/bin/env python3
"""Multi-Service Log Generator for Promtail, Loki, and Grafana Pipeline.

Generates realistic structured application and access logs across multiple services
(api, auth, billing) to test Promtail regex/JSON parsing and LogQL queries.
"""

import argparse
import datetime
import json
import os
import random
import sys
import time
import uuid

SERVICES = [
    {
        "app": "api",
        "service": "api-gateway",
        "file": "api.log",
        "endpoints": [
            ("/api/v1/products", 200, "INFO", "Product catalog retrieved"),
            ("/api/v1/search", 200, "INFO", "Product search executed"),
            ("/api/v1/cart/add", 200, "INFO", "Item added to cart"),
            ("/api/v1/checkout", 201, "INFO", "Order submitted for processing"),
            ("/api/v1/products/unknown", 404, "WARNING", "Product SKU not found"),
            ("/api/v1/checkout/fail", 500, "ERROR", "Internal checkout error: upstream database timeout"),
        ],
    },
    {
        "app": "auth",
        "service": "auth-service",
        "file": "auth.log",
        "endpoints": [
            ("/oauth/token", 200, "INFO", "OAuth bearer token issued"),
            ("/auth/login", 200, "INFO", "User login authenticated successfully"),
            ("/auth/verify", 200, "INFO", "Session JWT verified"),
            ("/auth/login/bad-pwd", 401, "WARNING", "Authentication failure: invalid password hash"),
            ("/auth/mfa/timeout", 401, "WARNING", "MFA token challenge expired"),
            ("/auth/ldap/error", 500, "ERROR", "LDAP server connection failure: connection refused"),
        ],
    },
    {
        "app": "billing",
        "service": "billing-service",
        "file": "billing.log",
        "endpoints": [
            ("/billing/charge", 200, "INFO", "Credit card charge authorized"),
            ("/billing/invoices/generate", 200, "INFO", "Monthly invoice generated"),
            ("/billing/webhooks/stripe", 200, "INFO", "Stripe payment intent webhook received"),
            ("/billing/charge/declined", 402, "WARNING", "Card transaction declined by issuer"),
            ("/billing/rate-limit", 429, "WARNING", "Stripe API rate limit exceeded: retry-after 30s"),
            ("/billing/gateway/timeout", 502, "ERROR", "Payment gateway timeout: connection dropped by peer"),
            ("/billing/db/deadlock", 500, "ERROR", "Database deadlock on ledger table: transaction rolled back"),
        ],
    },
]


def emit_log_event(log_dir: str) -> None:
    """Generate a single random log event and append to corresponding service log."""
    service_def = random.choice(SERVICES)
    endpoint, status_code, default_level, msg = random.choice(service_def["endpoints"])

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    trace_id = str(uuid.uuid4())

    latency = round(random.uniform(5.0, 150.0) if status_code < 500 else random.uniform(250.0, 1200.0), 2)

    event = {
        "timestamp": now,
        "level": default_level,
        "app": service_def["app"],
        "service": service_def["service"],
        "endpoint": endpoint,
        "status_code": status_code,
        "duration_ms": latency,
        "trace_id": trace_id,
        "message": msg,
        "context": {
            "client_ip": f"192.168.1.{random.randint(10, 250)}",
            "region": random.choice(["us-east-1", "eu-central-1", "ap-southeast-1"]),
        },
    }

    log_path = os.path.join(log_dir, service_def["file"])
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
        f.flush()


def run_generator(log_dir: str, count: int, interval: float, continuous: bool) -> None:
    """Run log generation loop."""
    os.makedirs(log_dir, exist_ok=True)
    print(f"[GENERATOR] Writing logs to {log_dir} (Target count: {count}, Continuous: {continuous})...", file=sys.stderr)

    generated = 0
    while continuous or generated < count:
        emit_log_event(log_dir)
        generated += 1

        if generated % 50 == 0:
            print(f"[GENERATOR] Emitted {generated} log events across services...", file=sys.stderr)

        if interval > 0:
            time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="Multi-service log producer for Loki pipeline.")
    parser.add_argument("--log-dir", default="/var/log/apps", help="Directory where log files are written")
    parser.add_argument("--count", type=int, default=300, help="Total number of initial logs to emit")
    parser.add_argument("--interval", type=float, default=0.05, help="Delay between logs in seconds")
    parser.add_argument("--continuous", action="store_true", help="Keep emitting logs indefinitely")
    args = parser.parse_args()

    run_generator(
        log_dir=args.log_dir,
        count=args.count,
        interval=args.interval,
        continuous=args.continuous,
    )


if __name__ == "__main__":
    main()
