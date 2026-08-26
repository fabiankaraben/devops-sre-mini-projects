"""Sample Application Emitting OTLP Traces, Metrics & Structured Logs to OpenTelemetry Collector."""

import os
import random
import time
import uuid
from typing import Any, Dict, List, Optional
from fastapi import FastAPI, HTTPException, Query, Request, status
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.trace import StatusCode
from pydantic import BaseModel, Field

from telemetry import get_current_trace_id, init_telemetry

# 1. Initialize OpenTelemetry Tracing & Metrics
tracer, meter = init_telemetry("sample-order-service")

# 2. Metric Instruments
orders_total_counter = meter.create_counter(
    name="orders_total",
    description="Total count of customer orders processed",
    unit="1",
)
order_amount_histogram = meter.create_histogram(
    name="order_amount",
    description="Monetary value distribution of processed orders",
    unit="USD",
)
active_users_gauge = meter.create_up_down_counter(
    name="active_users",
    description="Current count of active authenticated user sessions",
    unit="1",
)
product_views_counter = meter.create_counter(
    name="product_views_total",
    description="Total count of product catalog queries",
    unit="1",
)

# 3. Create FastAPI App & Instrument
app = FastAPI(
    title="OpenTelemetry Collector Sample Application",
    description="Demonstrates OTLP traces and metrics streaming through the OpenTelemetry Collector pipeline",
    version="1.0.0",
)
FastAPIInstrumentor.instrument_app(app)

COLLECTOR_URL = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")
JAEGER_UI_URL = os.getenv("JAEGER_UI_URL", "http://localhost:16686")
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://localhost:9090")


# ------------------------------------------------------------------------------
# Request & Response Models
# ------------------------------------------------------------------------------
class OrderItem(BaseModel):
    item_id: str = Field(default="prod-101", description="Product ID")
    name: str = Field(default="OpenTelemetry Collector Guide", description="Product title")
    price: float = Field(default=49.99, gt=0.0, description="Unit price")
    quantity: int = Field(default=1, ge=1, description="Quantity")


class CreateOrderRequest(BaseModel):
    customer_id: str = Field(default="cust-8821", description="Customer unique ID")
    customer_tier: str = Field(default="premium", description="Customer membership tier (standard/premium/enterprise)")
    items: List[OrderItem] = Field(
        default_factory=lambda: [
            OrderItem(item_id="prod-book-01", name="Observability Handbook", price=45.0, quantity=1),
            OrderItem(item_id="prod-stickers", name="OTel Hexagon Stickers", price=5.0, quantity=2),
        ]
    )
    currency: str = Field(default="USD", description="Currency code")


class SensitiveOrderRequest(BaseModel):
    customer_id: str = Field(default="cust-vip-99", description="Customer ID")
    credit_card: str = Field(
        default="4532-1234-5678-9012",
        description="Raw credit card number (will be sanitized to [REDACTED] by Collector)",
    )
    api_key: str = Field(
        default="sk_live_secret_key_88412",
        description="Private API key (will be stripped by Collector attribute processor)",
    )
    amount: float = Field(default=250.0, gt=0.0, description="Order amount")


# ------------------------------------------------------------------------------
# Middleware: Propagate Trace Headers
# ------------------------------------------------------------------------------
@app.middleware("http")
async def add_tracing_headers(request: Request, call_next):
    """Ensure X-Trace-ID is included in all response headers for manual verification."""
    response = await call_next(request)
    trace_id = get_current_trace_id()
    if trace_id:
        response.headers["X-Trace-ID"] = trace_id
    return response


# ------------------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------------------
@app.get("/healthz", tags=["System"])
async def healthz():
    """
    Health check probe endpoint.
    Note: OpenTelemetry Collector is configured with a filter processor to drop traces
    originating from this route to avoid cluttering tracing storage.
    """
    return {
        "status": "healthy",
        "service": "sample-order-service",
        "timestamp": time.time(),
    }


@app.get("/api/info", tags=["System"])
async def get_info():
    """Telemetry pipeline metadata and endpoint configuration."""
    return {
        "service": "sample-order-service",
        "version": "1.0.0",
        "collector_endpoint": COLLECTOR_URL,
        "jaeger_ui": JAEGER_UI_URL,
        "prometheus_ui": PROMETHEUS_URL,
        "exported_metrics": [
            "otel_orders_total",
            "otel_order_amount",
            "otel_active_users",
            "otel_product_views_total",
        ],
    }


@app.post("/api/orders", tags=["E-Commerce"])
async def create_order(req: CreateOrderRequest):
    """
    Standard order transaction.
    Emits multi-span distributed traces and increments OTLP metrics (orders_total, order_amount).
    """
    order_id = f"ord-{uuid.uuid4().hex[:8]}"
    start_time = time.time()
    trace_id = get_current_trace_id() or "unknown"

    with tracer.start_as_current_span("order.process") as span:
        total_amount = sum(item.price * item.quantity for item in req.items)
        span.set_attribute("order.id", order_id)
        span.set_attribute("customer.id", req.customer_id)
        span.set_attribute("customer.tier", req.customer_tier)
        span.set_attribute("order.total_amount", total_amount)
        span.set_attribute("order.currency", req.currency)
        span.set_attribute("order.items_count", len(req.items))

        # 1. Child Span: Inventory check
        with tracer.start_as_current_span("order.validate_inventory") as inv_span:
            time.sleep(0.01)
            inv_span.set_attribute("inventory.warehouse", "us-east-dc1")
            inv_span.add_event("stock_reserved", {"items_count": len(req.items)})

        # 2. Child Span: Payment Gateway
        with tracer.start_as_current_span("order.charge_payment") as pay_span:
            time.sleep(0.015)
            pay_span.set_attribute("payment.gateway", "mock_stripe")
            pay_span.set_attribute("payment.status", "AUTHORIZED")
            pay_span.add_event("payment_confirmed", {"amount": total_amount, "currency": req.currency})

        duration_sec = time.time() - start_time
        span.set_status(StatusCode.OK)

        # 3. Emit OTLP Metrics to OpenTelemetry Collector
        orders_total_counter.add(
            1,
            {
                "status": "success",
                "customer_tier": req.customer_tier,
                "currency": req.currency,
            },
        )
        order_amount_histogram.record(
            total_amount,
            {
                "customer_tier": req.customer_tier,
                "currency": req.currency,
            },
        )

        return {
            "status": "SUCCESS",
            "order_id": order_id,
            "total_amount": total_amount,
            "currency": req.currency,
            "customer_tier": req.customer_tier,
            "duration_ms": round(duration_sec * 1000.0, 2),
            "trace_id": trace_id,
            "jaeger_url": f"{JAEGER_UI_URL}/trace/{trace_id}",
        }


@app.post("/api/orders/sensitive", tags=["E-Commerce"])
async def create_sensitive_order(req: SensitiveOrderRequest):
    """
    Order with sensitive attributes to demonstrate OpenTelemetry Collector attribute processing:
    - credit_card: Will be updated/masked to '[REDACTED]' by the Collector
    - api_key: Will be deleted/stripped by the Collector
    - environment & datacenter: Will be injected into the span by the Collector
    """
    order_id = f"ord-sens-{uuid.uuid4().hex[:8]}"
    trace_id = get_current_trace_id() or "unknown"

    with tracer.start_as_current_span("order.process_sensitive") as span:
        span.set_attribute("order.id", order_id)
        span.set_attribute("customer.id", req.customer_id)
        span.set_attribute("order.amount", req.amount)

        # Attach sensitive raw data to demonstrate Collector transformation
        span.set_attribute("credit_card", req.credit_card)
        span.set_attribute("api_key", req.api_key)

        span.add_event("sensitive_order_received", {"masked_preview": req.credit_card[:4] + "-XXXX"})
        span.set_status(StatusCode.OK)

        # Emit OTLP metrics
        orders_total_counter.add(
            1,
            {"status": "sensitive_test", "customer_tier": "vip", "currency": "USD"},
        )
        order_amount_histogram.record(
            req.amount,
            {"customer_tier": "vip", "currency": "USD"},
        )

        return {
            "status": "SUCCESS",
            "order_id": order_id,
            "message": "Sensitive order processed. Inspect trace in Jaeger to verify Collector masking!",
            "trace_id": trace_id,
            "jaeger_url": f"{JAEGER_UI_URL}/trace/{trace_id}",
        }


@app.get("/api/products", tags=["Catalog"])
async def get_products(category: str = Query(default="books", description="Product category")):
    """Query product catalog, emitting search spans and product view metrics."""
    with tracer.start_as_current_span("product.catalog_search") as span:
        span.set_attribute("search.category", category)
        time.sleep(0.005)

        # Record metric in Collector pipeline
        product_views_counter.add(1, {"category": category})

        products = [
            {"id": "p-1", "name": f"{category.capitalize()} Item A", "price": 29.99},
            {"id": "p-2", "name": f"{category.capitalize()} Item B", "price": 49.50},
        ]
        span.set_attribute("search.results_count", len(products))

        return {
            "category": category,
            "count": len(products),
            "products": products,
        }


@app.post("/api/simulate-load", tags=["Testing"])
async def simulate_load(count: int = Query(default=10, ge=1, le=50, description="Number of events to generate")):
    """Generate a batch of simulated orders and product views to stream through the collector."""
    tiers = ["standard", "premium", "enterprise"]
    categories = ["books", "electronics", "cloud-hardware", "devops-swag"]

    active_users_gauge.add(random.randint(5, 15), {"app": "sample-order-service"})

    for i in range(count):
        tier = random.choice(tiers)
        amount = round(random.uniform(15.0, 350.0), 2)

        with tracer.start_as_current_span(f"batch.transaction_{i+1}") as span:
            span.set_attribute("batch.index", i + 1)
            span.set_attribute("customer.tier", tier)
            span.set_attribute("order.amount", amount)

            orders_total_counter.add(1, {"status": "success", "customer_tier": tier, "currency": "USD"})
            order_amount_histogram.record(amount, {"customer_tier": tier, "currency": "USD"})
            product_views_counter.add(random.randint(1, 4), {"category": random.choice(categories)})

    active_users_gauge.add(-random.randint(1, 5), {"app": "sample-order-service"})

    return {
        "status": "LOAD_SIMULATED",
        "generated_transactions": count,
        "message": f"Successfully streamed {count} transactions to OpenTelemetry Collector pipeline",
    }
