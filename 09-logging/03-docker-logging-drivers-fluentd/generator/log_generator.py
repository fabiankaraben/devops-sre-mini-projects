#!/usr/bin/env python3
"""High-Volume Log Generator for Docker Logging Driver Testing.

Generates exactly N monotonically indexed structured log records to stdout/stderr
to test Docker Daemon Forward logging to Fluentd without data loss.
"""

import argparse
import datetime
import json
import os
import sys
import time


def generate_logs(count: int, rate: float, service: str, error_rate: float) -> None:
    """Emit monotonic structured log records to standard output with batching."""
    start_time = time.perf_counter()

    batch_size = 50
    for seq in range(1, count + 1):
        now = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S.%f"
        )[:-3] + "Z"

        level = "INFO"
        if seq % 50 == 0:
            level = "ERROR"
        elif seq % 20 == 0:
            level = "WARNING"

        record = {
            "seq": seq,
            "timestamp": now,
            "level": level,
            "service": service,
            "message": f"Processed high-volume event #{seq} successfully",
            "context": {
                "transaction_id": f"tx_vol_{seq:06d}",
                "batch_id": f"batch_{seq // 500}",
                "latency_ms": round(1.5 + (seq % 10) * 0.4, 2),
                "worker_id": f"worker-{(seq % 4) + 1}",
                "payload_size_bytes": 256,
            },
        }

        sys.stdout.write(json.dumps(record, ensure_ascii=False) + "\n")

        if seq % batch_size == 0 or seq == count:
            sys.stdout.flush()
            if rate > 0:
                time.sleep(batch_size / rate)

    sys.stdout.flush()
    # Allow Docker daemon async logging driver ring buffer to flush to TCP socket
    time.sleep(2.0)

    duration = time.perf_counter() - start_time
    sys.stderr.write(
        f"[GENERATOR] Emitted {count} records in {duration:.2f}s ({count / max(0.001, duration):.0f} logs/sec)\n"
    )
    sys.stderr.flush()


def main():
    parser = argparse.ArgumentParser(
        description="Emit monotonic high-volume log stream for Docker logging driver validation."
    )
    parser.add_argument(
        "--count",
        type=int,
        default=10000,
        help="Total number of log events to emit (default: 10000)",
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=0.0,
        help="Rate limit in logs per second (0 = unthrottled burst, default: 0)",
    )
    parser.add_argument(
        "--service",
        default="high-volume-producer",
        help="Service name identifier in logs",
    )
    parser.add_argument(
        "--error-rate",
        type=float,
        default=0.05,
        help="Fraction of error/warning logs (default: 0.05)",
    )
    args = parser.parse_args()

    generate_logs(
        count=args.count,
        rate=args.rate,
        service=args.service,
        error_rate=args.error_rate,
    )


if __name__ == "__main__":
    main()
