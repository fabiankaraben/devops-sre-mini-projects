"""FastAPI Microservice demonstrating Structured JSON Logging & Error Scenarios."""

import asyncio
import os
import sys
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Query, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.config import settings
from app.logger import (
    bind_context,
    get_logger,
    get_trace_id,
    setup_logging,
)
from app.middleware import CorrelationAndAccessLogMiddleware

# Initialize Structured Logging Framework before app initialization
setup_logging()
logger = get_logger("app.service")


# ------------------------------------------------------------------------------
# Custom Exceptions for Structured Logging Demonstrations
# ------------------------------------------------------------------------------
class DatabaseDeadlockError(RuntimeError):
    """Exception simulating an ACID concurrency deadlock in the persistence layer."""

    def __init__(self, table: str, transaction_id: str):
        super().__init__(
            f"Deadlock detected on table '{table}' during transaction '{transaction_id}'."
        )
        self.table = table
        self.transaction_id = transaction_id
        self.code = "ERR_DB_DEADLOCK_40001"


class PaymentGatewayTimeoutError(RuntimeError):
    """Exception simulating an upstream third-party payment gateway timeout."""

    def __init__(self, provider: str, timeout_seconds: float):
        super().__init__(
            f"Gateway provider '{provider}' timed out after {timeout_seconds}s."
        )
        self.provider = provider
        self.timeout_seconds = timeout_seconds
        self.code = "ERR_PAYMENT_GATEWAY_TIMEOUT"


# ------------------------------------------------------------------------------
# Pydantic Schemas for Request Payloads
# ------------------------------------------------------------------------------
class OrderItem(BaseModel):
    sku: str = Field(..., example="WIDGET-PRO-100")
    quantity: int = Field(..., ge=1, example=2)
    unit_price: float = Field(..., ge=0.01, example=49.99)


class CreateOrderRequest(BaseModel):
    customer_id: str = Field(..., example="cust_98741")
    items: List[OrderItem]
    payment_method: str = Field(default="credit_card", example="credit_card")


class BatchProcessItem(BaseModel):
    id: str
    action: str
    should_fail: bool = False


class BatchProcessRequest(BaseModel):
    batch_name: str = Field(..., example="nightly_inventory_sync")
    items: List[BatchProcessItem]


# ------------------------------------------------------------------------------
# Application Lifespan Handler
# ------------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage application startup and graceful shutdown events."""
    logger.info(
        "Service starting up",
        extra={
            "context": {
                "event": "service_startup",
                "app_version": settings.app_version,
                "environment": settings.environment,
                "process_id": os.getpid(),
                "python_version": sys.version.split()[0],
            }
        },
    )
    yield
    logger.info(
        "Service shutting down gracefully",
        extra={
            "context": {
                "event": "service_shutdown",
                "process_id": os.getpid(),
            }
        },
    )


# ------------------------------------------------------------------------------
# FastAPI Application Instance
# ------------------------------------------------------------------------------
app = FastAPI(
    title="Structured JSON Logging Framework",
    description="Educational microservice showcasing standardized structured JSON logging, trace correlation, and error categorization.",
    version=settings.app_version,
    lifespan=lifespan,
)

# Register Correlation and Access Log Middleware
app.add_middleware(CorrelationAndAccessLogMiddleware)


# ------------------------------------------------------------------------------
# Global Exception Handlers
# ------------------------------------------------------------------------------
@app.exception_handler(DatabaseDeadlockError)
async def handle_db_deadlock(request: Request, exc: DatabaseDeadlockError):
    """Handle database deadlock exceptions and emit structured error logs."""
    logger.error(
        f"Database transaction aborted due to deadlock: {str(exc)}",
        exc_info=True,
        extra={
            "context": {
                "error_code": exc.code,
                "table": exc.table,
                "transaction_id": exc.transaction_id,
                "retryable": True,
            }
        },
    )
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={
            "error": "database_deadlock",
            "message": str(exc),
            "code": exc.code,
            "trace_id": get_trace_id(),
        },
    )


@app.exception_handler(PaymentGatewayTimeoutError)
async def handle_gateway_timeout(request: Request, exc: PaymentGatewayTimeoutError):
    """Handle external gateway timeout exceptions."""
    logger.error(
        f"Payment processing failed: {str(exc)}",
        exc_info=True,
        extra={
            "context": {
                "error_code": exc.code,
                "provider": exc.provider,
                "timeout_seconds": exc.timeout_seconds,
                "circuit_breaker": "open",
            }
        },
    )
    return JSONResponse(
        status_code=status.HTTP_502_BAD_GATEWAY,
        content={
            "error": "payment_gateway_timeout",
            "message": str(exc),
            "code": exc.code,
            "trace_id": get_trace_id(),
        },
    )


# ------------------------------------------------------------------------------
# API Endpoints
# ------------------------------------------------------------------------------
@app.get("/", summary="Root Endpoint")
async def root():
    """Service landing endpoint exposing API health and available routes."""
    return {
        "service": settings.service_name,
        "environment": settings.environment,
        "version": settings.app_version,
        "status": "operational",
        "documentation": "/docs",
    }


@app.get("/health", summary="Liveness Probe")
async def health():
    """Liveness probe verifying that the container process is responsive."""
    logger.debug(
        "Liveness check queried",
        extra={"context": {"probe_type": "liveness", "status": "healthy"}},
    )
    return {"status": "UP", "timestamp": str(asyncio.get_event_loop().time())}


@app.get("/ready", summary="Readiness Probe")
async def ready():
    """Readiness probe verifying backend dependency health."""
    logger.info(
        "Readiness probe passed all subsystem health checks",
        extra={
            "context": {
                "probe_type": "readiness",
                "subsystems": {
                    "database": "connected",
                    "cache": "connected",
                    "message_bus": "connected",
                },
            }
        },
    )
    return {"status": "READY", "service": settings.service_name}


@app.post("/api/orders", status_code=status.HTTP_201_CREATED, summary="Create Order")
async def create_order(payload: CreateOrderRequest):
    """Simulate a multi-step e-commerce transaction with rich contextual logs."""
    order_id = f"ord_{uuid.uuid4().hex[:8]}"
    total_amount = sum(item.quantity * item.unit_price for item in payload.items)

    # Bind customer and order ID to async context
    bind_context(order_id=order_id, customer_id=payload.customer_id)

    # Step 1: Order received
    logger.info(
        f"Order {order_id} received for processing",
        extra={
            "context": {
                "step": "order_received",
                "items_count": len(payload.items),
                "total_amount": round(total_amount, 2),
                "payment_method": payload.payment_method,
            }
        },
    )

    # Step 2: Inventory validation & reservation
    for item in payload.items:
        logger.info(
            f"Reserving stock for SKU {item.sku}",
            extra={
                "context": {
                    "step": "inventory_reservation",
                    "sku": item.sku,
                    "quantity": item.quantity,
                    "warehouse_id": "wh_east_01",
                }
            },
        )

    # Step 3: Payment authorization
    auth_code = f"AUTH_{uuid.uuid4().hex[:6].upper()}"
    logger.info(
        f"Payment authorized successfully for order {order_id}",
        extra={
            "context": {
                "step": "payment_authorization",
                "authorization_code": auth_code,
                "amount": round(total_amount, 2),
                "gateway": "stripe_v2",
            }
        },
    )

    # Step 4: Transaction commit
    logger.info(
        f"Order {order_id} successfully created and committed to database",
        extra={
            "context": {
                "step": "order_completed",
                "order_id": order_id,
                "status": "confirmed",
            }
        },
    )

    return {
        "order_id": order_id,
        "customer_id": payload.customer_id,
        "status": "confirmed",
        "total_amount": round(total_amount, 2),
        "auth_code": auth_code,
        "trace_id": get_trace_id(),
    }


@app.get("/api/inventory/{item_id}", summary="Check Inventory Item")
async def check_inventory(item_id: str, simulate_miss: bool = False):
    """Simulate cache hit/miss queries with latency and TTL metadata."""
    if simulate_miss or item_id.endswith("99"):
        logger.warning(
            f"Cache miss for inventory item '{item_id}'. Querying backing database.",
            extra={
                "context": {
                    "cache_hit": False,
                    "item_id": item_id,
                    "cache_backend": "redis_cluster",
                    "query_latency_ms": 42.15,
                }
            },
        )
        stock = 14
    else:
        logger.info(
            f"Cache hit for inventory item '{item_id}'",
            extra={
                "context": {
                    "cache_hit": True,
                    "item_id": item_id,
                    "cache_backend": "redis_cluster",
                    "cached_ttl_seconds": 298,
                    "query_latency_ms": 1.25,
                }
            },
        )
        stock = 150

    return {
        "item_id": item_id,
        "in_stock": True,
        "available_units": stock,
        "trace_id": get_trace_id(),
    }


@app.post("/api/checkout/payment-failure", summary="Simulate Payment Gateway Failure")
async def simulate_payment_failure():
    """Simulate an upstream third-party gateway timeout with retry attempts."""
    bind_context(gateway="paypal_checkout", operation="capture_charge")

    logger.warning(
        "Payment gateway attempt 1/3 timed out. Retrying with exponential backoff...",
        extra={"context": {"attempt": 1, "max_attempts": 3, "backoff_ms": 200}},
    )

    logger.warning(
        "Payment gateway attempt 2/3 timed out. Retrying with exponential backoff...",
        extra={"context": {"attempt": 2, "max_attempts": 3, "backoff_ms": 400}},
    )

    # Raise simulated exception which is caught by global exception handler
    raise PaymentGatewayTimeoutError(provider="paypal_checkout", timeout_seconds=5.0)


@app.get("/api/users/{user_id}", summary="Get User Details")
async def get_user(user_id: str):
    """Simulate user retrieval with 404 handling."""
    if user_id in ("missing", "404", "unknown") or user_id.startswith("err_"):
        logger.warning(
            f"User account not found for ID '{user_id}'",
            extra={
                "context": {
                    "user_id": user_id,
                    "reason": "user_id_does_not_exist",
                    "lookup_table": "users",
                }
            },
        )
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"User '{user_id}' not found in database.",
        )

    logger.info(
        f"User details fetched for ID '{user_id}'",
        extra={
            "context": {
                "user_id": user_id,
                "tier": "enterprise",
                "role": "billing_admin",
            }
        },
    )
    return {"user_id": user_id, "username": f"user_{user_id}", "status": "active"}


@app.get("/api/database/deadlock", summary="Simulate Database Deadlock")
async def simulate_deadlock():
    """Simulate an unrecoverable database concurrency deadlock emitting error stacktrace."""
    tx_id = f"tx_{uuid.uuid4().hex[:8]}"
    bind_context(transaction_id=tx_id, database="orders_db_primary")

    logger.info(
        "Acquiring row-level write locks for batch mutation",
        extra={"context": {"tables": ["accounts", "ledgers", "orders"]}},
    )

    # Trigger deadlock exception
    raise DatabaseDeadlockError(table="accounts_ledger", transaction_id=tx_id)


@app.get("/api/external/rate-limit", summary="Simulate Upstream Rate Limit")
async def simulate_rate_limit():
    """Simulate receiving a 429 Too Many Requests from an external partner API."""
    logger.warning(
        "Upstream logistics provider returned HTTP 429 Too Many Requests. Pausing requests.",
        extra={
            "context": {
                "upstream_service": "fedex_shipping_api",
                "rate_limit_bucket": "tier_1_standard",
                "retry_after_seconds": 60,
                "circuit_breaker": "half_open",
            }
        },
    )
    return JSONResponse(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        headers={"Retry-After": "60"},
        content={
            "error": "rate_limit_exceeded",
            "message": "Upstream service quota exceeded. Please retry after 60 seconds.",
            "retry_after_seconds": 60,
            "trace_id": get_trace_id(),
        },
    )


@app.post("/api/batch/process", summary="Simulate Batch Processing")
async def process_batch(request: BatchProcessRequest):
    """Simulate batch iteration with item-level logs, failure handling, and summary metrics."""
    total_items = len(request.items)
    success_count = 0
    failure_count = 0

    bind_context(batch_name=request.batch_name, total_items=total_items)

    logger.info(
        f"Starting batch execution '{request.batch_name}' with {total_items} items",
        extra={"context": {"event": "batch_started"}},
    )

    for index, item in enumerate(request.items, start=1):
        if item.should_fail:
            failure_count += 1
            logger.error(
                f"Failed to process batch item [{index}/{total_items}]: ID {item.id}",
                extra={
                    "context": {
                        "item_id": item.id,
                        "action": item.action,
                        "index": index,
                        "error_reason": "schema_validation_failed",
                    }
                },
            )
        else:
            success_count += 1
            logger.info(
                f"Successfully processed batch item [{index}/{total_items}]: ID {item.id}",
                extra={
                    "context": {
                        "item_id": item.id,
                        "action": item.action,
                        "index": index,
                        "processed_bytes": 1024 * index,
                    }
                },
            )

    logger.info(
        f"Batch execution '{request.batch_name}' completed. Success: {success_count}, Failed: {failure_count}",
        extra={
            "context": {
                "event": "batch_finished",
                "success_count": success_count,
                "failure_count": failure_count,
                "success_rate_percent": round(
                    (success_count / total_items) * 100, 2
                )
                if total_items > 0
                else 100.0,
            }
        },
    )

    return {
        "batch_name": request.batch_name,
        "total_items": total_items,
        "successful": success_count,
        "failed": failure_count,
        "trace_id": get_trace_id(),
    }


@app.get("/api/auth/unauthorized", summary="Simulate Authentication Failure")
async def simulate_unauthorized(request: Request):
    """Simulate a security event where an invalid token or missing credential is provided."""
    client_ip = request.client.host if request.client else "127.0.0.1"
    logger.warning(
        "Unauthorized access attempt detected: invalid JWT signature",
        extra={
            "context": {
                "security_event": "auth_failure",
                "attempted_resource": "/api/admin/secrets",
                "client_ip": client_ip,
                "auth_header_present": False,
            }
        },
    )
    return JSONResponse(
        status_code=status.HTTP_401_UNAUTHORIZED,
        headers={"WWW-Authenticate": "Bearer"},
        content={
            "error": "unauthorized",
            "message": "Missing or invalid authentication token.",
            "trace_id": get_trace_id(),
        },
    )


@app.get("/api/scenarios/run-all", summary="Run All Test Scenarios")
async def run_all_scenarios():
    """Trigger all microservice logging scenarios sequentially to generate a rich log stream."""
    results: Dict[str, Any] = {}

    # 1. Health & readiness
    await health()
    await ready()
    results["health_and_readiness"] = "executed"

    # 2. Order creation
    order_req = CreateOrderRequest(
        customer_id="cust_demo_123",
        items=[
            OrderItem(sku="PROD-A", quantity=1, unit_price=19.99),
            OrderItem(sku="PROD-B", quantity=3, unit_price=9.50),
        ],
    )
    results["order_creation"] = await create_order(order_req)

    # 3. Cache hit & miss
    results["cache_hit"] = await check_inventory("item_101", simulate_miss=False)
    results["cache_miss"] = await check_inventory("item_99", simulate_miss=True)

    # 4. Batch processing
    batch_req = BatchProcessRequest(
        batch_name="all_scenarios_batch",
        items=[
            BatchProcessItem(id="item-1", action="sync", should_fail=False),
            BatchProcessItem(id="item-2", action="delete", should_fail=True),
            BatchProcessItem(id="item-3", action="archive", should_fail=False),
        ],
    )
    results["batch_processing"] = await process_batch(batch_req)

    logger.info(
        "All test scenarios executed successfully",
        extra={"context": {"total_scenarios_run": 5, "status": "completed"}},
    )

    return {
        "status": "all_scenarios_completed",
        "results": results,
        "trace_id": get_trace_id(),
    }


# ------------------------------------------------------------------------------
# Direct Process Entrypoint
# ------------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        log_config=None,  # Handled by our custom structured logger
        access_log=False,  # Handled by our custom ASGI middleware
    )
