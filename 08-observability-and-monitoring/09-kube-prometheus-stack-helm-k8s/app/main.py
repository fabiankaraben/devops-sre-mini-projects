"""Sample Kubernetes Microservice Emitting Prometheus RED & USE Metrics."""

import random
import time
from typing import Dict, List, Optional
from fastapi import FastAPI, HTTPException, Request, Response, status
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel, Field

app = FastAPI(
    title="Order Processing API",
    description="Sample microservice instrumented for Kubernetes Prometheus Operator discovery",
    version="1.0.0",
)

# ------------------------------------------------------------------------------
# Prometheus Metric Instruments
# ------------------------------------------------------------------------------
http_requests_counter = Counter(
    "http_requests_total",
    "Total HTTP requests received by the application",
    ["method", "endpoint", "status"],
)

http_request_duration_hist = Histogram(
    "http_request_duration_seconds",
    "HTTP request execution latency distribution",
    ["endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

orders_processed_counter = Counter(
    "orders_processed_total",
    "Total count of successfully processed e-commerce customer orders",
    ["customer_tier", "currency"],
)

inventory_stock_gauge = Gauge(
    "inventory_stock_gauge",
    "Current stock level across regional fulfillment centers",
    ["warehouse", "category"],
)

# Initialize initial gauge values
inventory_stock_gauge.labels(warehouse="us-east-1", category="electronics").set(1250)
inventory_stock_gauge.labels(warehouse="us-east-1", category="books").set(4820)
inventory_stock_gauge.labels(warehouse="eu-west-1", category="electronics").set(890)


# ------------------------------------------------------------------------------
# Request Models
# ------------------------------------------------------------------------------
class OrderRequest(BaseModel):
    customer_id: str = Field(default="cust-1001", description="Customer ID")
    customer_tier: str = Field(default="premium", description="Customer membership tier")
    currency: str = Field(default="USD", description="Currency code")
    amount: float = Field(default=99.50, gt=0.0, description="Order total amount")


# ------------------------------------------------------------------------------
# Middleware: Record HTTP Request Metrics
# ------------------------------------------------------------------------------
@app.middleware("http")
async def record_metrics_middleware(request: Request, call_next):
    start_time = time.time()
    endpoint = request.url.path
    method = request.method

    try:
        response = await call_next(request)
        status_code = str(response.status_code)
    except Exception as exc:
        status_code = "500"
        raise exc from None
    finally:
        duration = time.time() - start_time
        # Only record API routes (exclude /metrics from latency histogram to prevent noise)
        if endpoint != "/metrics":
            http_requests_counter.labels(method=method, endpoint=endpoint, status=status_code).inc()
            http_request_duration_hist.labels(endpoint=endpoint).observe(duration)

    return response


# ------------------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------------------
@app.get("/healthz", tags=["System"])
async def healthz():
    """Liveness probe endpoint."""
    return {"status": "healthy", "service": "order-api", "timestamp": time.time()}


@app.get("/metrics", tags=["Observability"])
async def metrics():
    """Expose Prometheus exposition format."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/info", tags=["System"])
async def get_info():
    """Service metadata."""
    return {
        "service": "order-api",
        "version": "1.0.0",
        "instrumentation": "Prometheus Client Python",
        "monitored_by": "Prometheus Operator (ServiceMonitor / PodMonitor)",
    }


@app.post("/api/orders", tags=["E-Commerce"])
async def create_order(req: OrderRequest):
    """Process an order transaction and emit order metrics."""
    # Simulate realistic business processing delay (10-30ms)
    time.sleep(random.uniform(0.01, 0.03))

    orders_processed_counter.labels(customer_tier=req.customer_tier, currency=req.currency).inc()
    inventory_stock_gauge.labels(warehouse="us-east-1", category="electronics").dec(1)

    return {
        "status": "ORDER_CONFIRMED",
        "customer_id": req.customer_id,
        "amount": req.amount,
        "currency": req.currency,
        "processed_at": time.time(),
    }


@app.post("/api/simulate-error", tags=["Testing"])
async def simulate_error():
    """Simulate a 500 Internal Server Error to trigger PrometheusRule alerting."""
    time.sleep(0.02)
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="Simulated database deadlock for alert verification",
    )
