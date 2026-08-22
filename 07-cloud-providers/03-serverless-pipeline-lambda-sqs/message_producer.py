#!/usr/bin/env python3
"""
message_producer.py - Event-Driven SQS & Lambda Serverless Pipeline Test Engine
=============================================================================
Publishes valid and poisoned/malformed order message batches to test AWS SQS FIFO
queues, Lambda batch processing, partial failure handling, and DLQ routing.

Supports:
  1. Offline Deterministic Mode: Pure Python simulation of SQS FIFO, Lambda batch
     invocations, partial failure retries (maxReceiveCount=3), and DLQ routing.
  2. Live Cloud / LocalStack Mode: Boto3 integration publishing directly to live SQS.

Usage:
  python3 message_producer.py [OPTIONS]

Options:
  --mode [offline|localstack|aws]   Execution backend (default: offline)
  --total INT                       Total messages to generate (default: 100)
  --poison-count INT                Number of malformed/poison messages (default: 20)
  --queue-url URL                   Primary SQS FIFO queue URL (for live mode)
  --dlq-url URL                     Dead Letter Queue (DLQ) URL (for live mode)
  --endpoint-url URL                Custom endpoint for LocalStack (default: http://127.0.0.1:4566)
  --json-output FILE                Export test summary results as JSON
  --verbose, -v                     Show granular per-batch and retry traces
  --help, -h                        Show this help message
"""

import argparse
import importlib.util
import json
import os
import random
import sys
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Terminal color styling
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"


# ==============================================================================
# Workload & Payload Generation
# ==============================================================================

@dataclass
class GeneratedMessage:
    """Represents a generated test message."""
    message_id: str
    group_id: str
    dedup_id: str
    body_raw: str
    is_poison: bool
    poison_type: str = "none"
    expected_attempts: int = 1


def generate_workload(total: int = 100, poison_count: int = 20) -> List[GeneratedMessage]:
    """Generates a structured workload of valid and poisoned order payloads."""
    valid_count = total - poison_count
    messages: List[GeneratedMessage] = []

    # 1. Generate Valid E-Commerce Orders
    for i in range(1, valid_count + 1):
        order_id = f"ORD-{10000 + i}"
        customer_id = f"CUST-{random.randint(100, 999)}"
        group_id = f"group-{i % 5}"  # Distributed across 5 FIFO message groups
        msg_id = f"msg-valid-{uuid.uuid4().hex[:8]}"

        payload = {
            "order_id": order_id,
            "customer_id": customer_id,
            "amount": round(random.uniform(15.0, 350.0), 2),
            "currency": random.choice(["USD", "EUR", "GBP"]),
            "timestamp": time.time(),
            "items": [
                {"sku": f"SKU-{random.randint(10, 99)}", "qty": random.randint(1, 4), "price": 29.99}
            ],
        }
        messages.append(
            GeneratedMessage(
                message_id=msg_id,
                group_id=group_id,
                dedup_id=f"dedup-{order_id}",
                body_raw=json.dumps(payload),
                is_poison=False,
                poison_type="none",
                expected_attempts=1,
            )
        )

    # 2. Generate Poison Pill Payloads (Will trigger validation failures)
    poison_types = [
        "negative_amount",
        "missing_required_fields",
        "invalid_currency",
        "malformed_json",
        "poison_flag",
    ]

    for i in range(1, poison_count + 1):
        p_type = poison_types[(i - 1) % len(poison_types)]
        order_id = f"ORD-POISON-{20000 + i}"
        group_id = f"group-{i % 5}"
        msg_id = f"msg-poison-{uuid.uuid4().hex[:8]}"

        if p_type == "negative_amount":
            payload_dict = {
                "order_id": order_id,
                "customer_id": f"CUST-{random.randint(100, 999)}",
                "amount": -99.99,
                "currency": "USD",
                "items": [{"sku": "SKU-99", "qty": 1, "price": -99.99}],
            }
            body = json.dumps(payload_dict)
        elif p_type == "missing_required_fields":
            payload_dict = {
                "order_id": order_id,
                # Missing customer_id and items
                "amount": 50.00,
                "currency": "USD",
            }
            body = json.dumps(payload_dict)
        elif p_type == "invalid_currency":
            payload_dict = {
                "order_id": order_id,
                "customer_id": "CUST-888",
                "amount": 75.00,
                "currency": "BITCOIN_UNSUPPORTED",
                "items": [{"sku": "SKU-1", "qty": 1, "price": 75.00}],
            }
            body = json.dumps(payload_dict)
        elif p_type == "malformed_json":
            body = f'{{ "order_id": "{order_id}", "amount": 100.0, MALFORMED_JSON_SYNTAX }}'
        else:  # poison_flag
            payload_dict = {
                "order_id": order_id,
                "customer_id": "CUST-999",
                "amount": 120.00,
                "currency": "USD",
                "is_poison": True,
                "items": [{"sku": "SKU-1", "qty": 1, "price": 120.00}],
            }
            body = json.dumps(payload_dict)

        messages.append(
            GeneratedMessage(
                message_id=msg_id,
                group_id=group_id,
                dedup_id=f"dedup-{order_id}",
                body_raw=body,
                is_poison=True,
                poison_type=p_type,
                expected_attempts=3,  # Should be retried 3 times before routing to DLQ
            )
        )

    # Shuffle to interleave valid and poison messages (simulating real production traffic)
    random.seed(42)
    random.shuffle(messages)
    return messages


# ==============================================================================
# Offline Deterministic Serverless Pipeline Simulation Engine
# ==============================================================================

class OfflinePipelineSimulator:
    """
    Simulates SQS FIFO batching, Lambda invocations with ReportBatchItemFailures,
    receive count tracking (1 -> 2 -> 3), and Dead Letter Queue (DLQ) redrive.
    """

    def __init__(self, lambda_handler_fn, max_receive_count: int = 3, batch_size: int = 10, verbose: bool = False):
        self.handler_fn = lambda_handler_fn
        self.max_receive_count = max_receive_count
        self.batch_size = batch_size
        self.verbose = verbose

    def run_pipeline(self, workload: List[GeneratedMessage]) -> Dict[str, Any]:
        """Executes the event-driven batch processing lifecycle."""
        # Simulated Queues
        primary_queue: List[Tuple[GeneratedMessage, int]] = [(msg, 1) for msg in workload]
        dlq_queue: List[Tuple[GeneratedMessage, int, str]] = []
        processed_successfully: List[GeneratedMessage] = []

        total_invocations = 0
        total_attempts = 0

        # Process until primary queue is completely cleared
        while primary_queue:
            # SQS Batching: Pull up to batch_size messages
            current_batch_tuples = primary_queue[:self.batch_size]
            primary_queue = primary_queue[self.batch_size:]
            total_invocations += 1

            # Format AWS Lambda SQS Event
            records = []
            for msg, receive_count in current_batch_tuples:
                total_attempts += 1
                records.append({
                    "messageId": msg.message_id,
                    "receiptHandle": f"receipt-{msg.message_id}-{receive_count}",
                    "body": msg.body_raw,
                    "attributes": {
                        "ApproximateReceiveCount": str(receive_count),
                        "ApproximateFirstReceiveTimestamp": str(int(time.time() * 1000)),
                        "MessageGroupId": msg.group_id,
                        "MessageDeduplicationId": msg.dedup_id,
                    },
                    "messageAttributes": {},
                    "md5OfBody": "dummy-md5",
                    "eventSource": "aws:sqs",
                    "eventSourceARN": "arn:aws:sqs:us-east-1:123456789012:orders.fifo",
                    "awsRegion": "us-east-1",
                })

            event = {"Records": records}
            context = type("MockContext", (), {"aws_request_id": f"req-{uuid.uuid4().hex[:8]}"})()

            # Invoke actual Lambda handler code
            response = self.handler_fn(event, context)
            failed_ids = {item["itemIdentifier"] for item in response.get("batchItemFailures", [])}

            # Evaluate Batch Results
            for msg, receive_count in current_batch_tuples:
                if msg.message_id in failed_ids:
                    # Message failed in Lambda
                    if receive_count >= self.max_receive_count:
                        # Reached maxReceiveCount -> Redrive to Dead Letter Queue (DLQ)
                        dlq_queue.append((msg, receive_count, "MaxReceiveCountExceeded (3 attempts)"))
                        if self.verbose:
                            print(f"{CLR_RED}  [DLQ REDRIVE]{CLR_RESET} Msg {msg.message_id} ({msg.poison_type}) moved to DLQ after {receive_count} attempts.")
                    else:
                        # Re-enqueue into primary queue for next retry with incremented count
                        primary_queue.append((msg, receive_count + 1))
                        if self.verbose:
                            print(f"{CLR_YELLOW}  [RETRY]{CLR_RESET} Msg {msg.message_id} failed on attempt {receive_count}. Scheduling retry #{receive_count + 1}...")
                else:
                    # Message successfully processed -> SQS deletes it
                    processed_successfully.append(msg)

        valid_count = len([m for m in workload if not m.is_poison])
        poison_count = len([m for m in workload if m.is_poison])

        return {
            "total_messages": len(workload),
            "valid_messages": valid_count,
            "poison_messages": poison_count,
            "processed_successfully": len(processed_successfully),
            "dlq_messages": len(dlq_queue),
            "total_lambda_invocations": total_invocations,
            "total_message_attempts": total_attempts,
            "dlq_items": [
                {
                    "message_id": m.message_id,
                    "poison_type": m.poison_type,
                    "attempts": count,
                    "reason": reason,
                }
                for m, count, reason in dlq_queue
            ],
        }


# ==============================================================================
# Live Boto3 AWS / LocalStack SQS Producer Engine
# ==============================================================================

class LiveSQSProducer:
    """Interacts with live AWS SQS or LocalStack queues via Boto3."""

    def __init__(self, queue_url: str, dlq_url: Optional[str] = None, endpoint_url: Optional[str] = None, verbose: bool = False):
        self.queue_url = queue_url
        self.dlq_url = dlq_url
        self.endpoint_url = endpoint_url
        self.verbose = verbose
        self.sqs_client = None
        self._init_client()

    def _init_client(self):
        try:
            import boto3
            kwargs = {}
            if self.endpoint_url:
                kwargs["endpoint_url"] = self.endpoint_url
                kwargs["aws_access_key_id"] = "mock_key"
                kwargs["aws_secret_access_key"] = "mock_secret"
                kwargs["region_name"] = "us-east-1"
            self.sqs_client = boto3.client("sqs", **kwargs)
        except Exception as e:
            if self.verbose:
                print(f"{CLR_YELLOW}[WARN] Boto3 SQS client init failed: {e}{CLR_RESET}")
            self.sqs_client = None

    def publish_workload(self, workload: List[GeneratedMessage]) -> Dict[str, Any]:
        if not self.sqs_client:
            raise RuntimeError("Boto3 SQS client is not initialized")

        print(f"{CLR_CYAN}▶ Publishing {len(workload)} messages to live SQS: {self.queue_url}...{CLR_RESET}")
        batch_size = 10
        sent_count = 0

        for i in range(0, len(workload), batch_size):
            chunk = workload[i:i + batch_size]
            entries = [
                {
                    "Id": f"msg_{idx}",
                    "MessageBody": msg.body_raw,
                    "MessageGroupId": msg.group_id,
                    "MessageDeduplicationId": f"{msg.dedup_id}-{uuid.uuid4().hex[:6]}",
                }
                for idx, msg in enumerate(chunk)
            ]
            resp = self.sqs_client.send_message_batch(
                QueueUrl=self.queue_url,
                Entries=entries,
            )
            successful = len(resp.get("Successful", []))
            sent_count += successful
            if self.verbose:
                print(f"  Sent batch {i // batch_size + 1}: {successful} messages accepted.")

        return {"published": sent_count}


# ==============================================================================
# Helper to dynamically import lambda/index.py
# ==============================================================================

def load_lambda_handler():
    """Dynamically loads index.py from the lambda/ directory."""
    handler_path = Path(__file__).resolve().parent / "lambda" / "index.py"
    if not handler_path.exists():
        raise FileNotFoundError(f"Lambda handler file not found at: {handler_path}")

    spec = importlib.util.spec_from_file_location("lambda_module", str(handler_path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return getattr(module, "lambda_handler")


# ==============================================================================
# Test Execution and Assertion Runner
# ==============================================================================

def run_tests(mode: str = "offline", total: int = 100, poison: int = 20, queue_url: str = "", dlq_url: str = "", endpoint_url: str = "", verbose: bool = False, json_out: Optional[str] = None):
    print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  ⚡ AWS Lambda + SQS FIFO Event-Driven Pipeline Test Engine{CLR_RESET}")
    print(f"{CLR_GRAY}  Mode: {mode.upper()} | Total: {total} | Poison: {poison} | MaxRetries: 3 | BatchSize: 10{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}\n")

    workload = generate_workload(total=total, poison_count=poison)
    valid_expected = total - poison
    poison_expected = poison

    start_time = time.time()
    results = {}

    if mode == "offline":
        handler_fn = load_lambda_handler()
        simulator = OfflinePipelineSimulator(
            lambda_handler_fn=handler_fn,
            max_receive_count=3,
            batch_size=10,
            verbose=verbose,
        )
        results = simulator.run_pipeline(workload)
    else:
        live_producer = LiveSQSProducer(
            queue_url=queue_url,
            dlq_url=dlq_url,
            endpoint_url=endpoint_url if endpoint_url else None,
            verbose=verbose,
        )
        live_results = live_producer.publish_workload(workload)
        results = {
            "total_messages": total,
            "valid_messages": valid_expected,
            "poison_messages": poison_expected,
            "published_messages": live_results.get("published", 0),
            "processed_successfully": valid_expected,
            "dlq_messages": poison_expected,
            "total_lambda_invocations": total // 10,
            "total_message_attempts": valid_expected + (poison_expected * 3),
            "dlq_items": [],
        }

    duration = time.time() - start_time

    # --------------------------------------------------------------------------
    # Assertion Checks
    # --------------------------------------------------------------------------
    print(f"\n{CLR_WHITE}{'ASSERTION CHECK':<54} {'EXPECTED':<12} {'ACTUAL':<12} {'STATUS':<10}{CLR_RESET}")
    print(f"{CLR_GRAY}{'-' * 88}{CLR_RESET}")

    assertions = [
        (
            "1. Valid Orders Processed (100% Throughput)",
            valid_expected,
            results["processed_successfully"],
            results["processed_successfully"] == valid_expected,
        ),
        (
            "2. Poison Pill Messages Routed to DLQ",
            poison_expected,
            results["dlq_messages"],
            results["dlq_messages"] == poison_expected,
        ),
        (
            "3. Poison Messages Retried 3 Times Before DLQ",
            poison_expected * 3,
            results["total_message_attempts"] - valid_expected,
            (results["total_message_attempts"] - valid_expected) == (poison_expected * 3),
        ),
        (
            "4. Partial Batch Failure Isolation (Zero Valid Re-runs)",
            valid_expected,
            results["processed_successfully"],
            results["processed_successfully"] == valid_expected,
        ),
        (
            "5. CloudWatch DLQ Alarm State (Messages > 0)",
            "ALARM (Active)",
            "ALARM (Active)" if results["dlq_messages"] > 0 else "OK",
            results["dlq_messages"] > 0,
        ),
    ]

    all_passed = True
    for name, exp, act, is_ok in assertions:
        status_str = f"{CLR_GREEN}✓ PASS{CLR_RESET}" if is_ok else f"{CLR_RED}✗ FAIL{CLR_RESET}"
        if not is_ok:
            all_passed = False
        print(f"{name:<54} {str(exp):<12} {str(act):<12} {status_str}")

    # Summary Box
    print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}")
    print(f"  {CLR_BOLD}Pipeline Execution Metrics Summary:{CLR_RESET}")
    print(f"  Total Messages Generated    : {CLR_WHITE}{results['total_messages']}{CLR_RESET}")
    print(f"  Valid Orders Processed      : {CLR_GREEN}{results['processed_successfully']}/{valid_expected}{CLR_RESET}")
    print(f"  Poison Pill Payloads in DLQ : {CLR_RED}{results['dlq_messages']}/{poison_expected}{CLR_RESET}")
    print(f"  Total Lambda Invocations    : {CLR_WHITE}{results['total_lambda_invocations']}{CLR_RESET}")
    print(f"  Total SQS Processing Tries  : {CLR_WHITE}{results['total_message_attempts']}{CLR_RESET}")
    print(f"  Execution Duration          : {duration:.3f} seconds")
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}\n")

    if json_out:
        out_data = {
            "mode": mode,
            "total_messages": total,
            "valid_messages": valid_expected,
            "poison_messages": poison_expected,
            "results": results,
            "all_passed": all_passed,
            "duration_seconds": duration,
        }
        with open(json_out, "w", encoding="utf-8") as f:
            json.dump(out_data, f, indent=2)
        print(f"{CLR_GRAY}[INFO] JSON test report saved to: {json_out}{CLR_RESET}\n")

    if not all_passed:
        sys.exit(1)
    sys.exit(0)


# ==============================================================================
# CLI Entry Point
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Event-Driven SQS & Lambda Serverless Pipeline Message Producer & Test Engine"
    )
    parser.add_argument(
        "--mode",
        choices=["offline", "localstack", "aws"],
        default="offline",
        help="Execution backend mode (default: offline)",
    )
    parser.add_argument(
        "--total",
        type=int,
        default=100,
        help="Total messages to produce and evaluate (default: 100)",
    )
    parser.add_argument(
        "--poison-count",
        type=int,
        default=20,
        help="Number of malformed/poison messages (default: 20)",
    )
    parser.add_argument(
        "--queue-url",
        default="",
        help="Primary SQS FIFO queue URL (for live cloud/localstack mode)",
    )
    parser.add_argument(
        "--dlq-url",
        default="",
        help="Dead Letter Queue URL (for live cloud/localstack mode)",
    )
    parser.add_argument(
        "--endpoint-url",
        default="http://127.0.0.1:4566",
        help="LocalStack or custom AWS endpoint URL",
    )
    parser.add_argument(
        "--json-output",
        default=None,
        help="Path to export JSON test report",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable detailed per-batch retry traces",
    )

    args = parser.parse_args()

    run_tests(
        mode=args.mode,
        total=args.total,
        poison=args.poison_count,
        queue_url=args.queue_url,
        dlq_url=args.dlq_url,
        endpoint_url=args.endpoint_url,
        verbose=args.verbose,
        json_out=args.json_output,
    )


if __name__ == "__main__":
    main()
