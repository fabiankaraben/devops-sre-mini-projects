"""
AWS Lambda SQS Event Processing Handler
=============================================================================
Processes batches of e-commerce order messages from an SQS FIFO queue with
granular partial batch failure reporting (ReportBatchItemFailures).

Features:
  - Validates JSON payload schema and business rules.
  - Returns batchItemFailures for poisoned/invalid messages, allowing SQS to
    redrive failed items to the Dead Letter Queue (DLQ) after maxReceiveCount
    without re-processing successfully processed messages in the same batch.
  - Emits structured JSON logs for CloudWatch Insights querying.
=============================================================================
"""

import json
import logging
import os
import time
from typing import Any, Dict, List

# Configure structured logging
logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())


def validate_order(order: Dict[str, Any]) -> None:
    """
    Validates mandatory order fields and business logic constraints.
    Raises ValueError on validation failures (poison pill payloads).
    """
    # 1. Check for intentional test poison pill flag
    if order.get("is_poison") is True:
        raise ValueError(f"Poison pill detected in order {order.get('order_id', 'UNKNOWN')}: Forced failure for DLQ test")

    # 2. Check required attributes
    required_fields = ["order_id", "customer_id", "amount", "currency", "items"]
    missing = [f for f in required_fields if f not in order]
    if missing:
        raise ValueError(f"Missing required field(s): {', '.join(missing)}")

    # 3. Validate order ID format
    order_id = str(order["order_id"])
    if not order_id.startswith("ORD-"):
        raise ValueError(f"Invalid order_id format '{order_id}'. Must start with 'ORD-'")

    # 4. Validate amount
    try:
        amount = float(order["amount"])
        if amount <= 0:
            raise ValueError(f"Invalid order amount {amount}. Must be strictly positive.")
    except (ValueError, TypeError) as e:
        raise ValueError(f"Invalid amount value: {e}")

    # 5. Validate currency
    allowed_currencies = {"USD", "EUR", "GBP", "CAD", "AUD"}
    currency = str(order["currency"]).upper()
    if currency not in allowed_currencies:
        raise ValueError(f"Unsupported currency '{currency}'. Allowed: {', '.join(allowed_currencies)}")

    # 6. Validate items list
    items = order.get("items", [])
    if not isinstance(items, list) or len(items) == 0:
        raise ValueError("Order must contain at least one line item in 'items' array")


def process_message(record: Dict[str, Any]) -> None:
    """
    Simulates business execution for a single SQS message (e.g. inventory check, billing).
    """
    message_id = record.get("messageId", "unknown-msg-id")
    body_raw = record.get("body", "{}")
    attributes = record.get("attributes", {})
    receive_count = attributes.get("ApproximateReceiveCount", "1")

    logger.info(
        json.dumps({
            "event": "processing_message_start",
            "message_id": message_id,
            "receive_count": receive_count,
            "approximate_first_receive_timestamp": attributes.get("ApproximateFirstReceiveTimestamp"),
        })
    )

    # Parse JSON payload
    try:
        order_data = json.loads(body_raw)
    except Exception as e:
        raise ValueError(f"Malformed JSON payload: {e}")

    # Business Validation
    validate_order(order_data)

    # Simulated lightweight business transaction
    order_id = order_data["order_id"]
    customer_id = order_data["customer_id"]
    amount = order_data["amount"]
    currency = order_data["currency"]

    logger.info(
        json.dumps({
            "event": "order_processed_success",
            "message_id": message_id,
            "order_id": order_id,
            "customer_id": customer_id,
            "amount": amount,
            "currency": currency,
            "status": "CONFIRMED",
        })
    )


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda Handler entry point for SQS FIFO batch event source mappings.
    Returns:
        { "batchItemFailures": [ { "itemIdentifier": "<message-id>" }, ... ] }
    """
    records: List[Dict[str, Any]] = event.get("Records", [])
    batch_size = len(records)
    batch_item_failures: List[Dict[str, str]] = []

    logger.info(
        json.dumps({
            "event": "batch_received",
            "batch_size": batch_size,
            "aws_request_id": getattr(context, "aws_request_id", "local-test-req-id"),
        })
    )

    for record in records:
        message_id = record.get("messageId", "")
        try:
            process_message(record)
        except Exception as err:
            logger.error(
                json.dumps({
                    "event": "message_processing_failed",
                    "message_id": message_id,
                    "error_type": type(err).__name__,
                    "error_message": str(err),
                })
            )
            # Add failed message ID to batchItemFailures list
            batch_item_failures.append({"itemIdentifier": message_id})

    success_count = batch_size - len(batch_item_failures)
    failed_count = len(batch_item_failures)

    logger.info(
        json.dumps({
            "event": "batch_completed",
            "batch_size": batch_size,
            "success_count": success_count,
            "failed_count": failed_count,
            "batch_item_failures_count": len(batch_item_failures),
        })
    )

    return {"batchItemFailures": batch_item_failures}
