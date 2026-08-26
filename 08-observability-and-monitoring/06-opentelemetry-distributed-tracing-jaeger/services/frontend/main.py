"""Frontend Microservice (API Gateway) with OpenTelemetry Distributed Tracing."""

import os
import time
import uuid
from typing import Any, Dict, List, Optional
import httpx
from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.trace import StatusCode
from pydantic import BaseModel, Field

from telemetry import get_current_span_id, get_current_trace_id, init_telemetry

# 1. Initialize OpenTelemetry Tracing
tracer = init_telemetry("frontend-service")

# 2. Instrument HTTPX client for automatic W3C traceparent header injection
HTTPXClientInstrumentor().instrument()

# 3. Create FastAPI application
app = FastAPI(
    title="Frontend Microservice",
    description="Frontend API Gateway demonstrating OpenTelemetry distributed tracing and W3C context propagation",
    version="1.0.0",
)

# 4. Instrument FastAPI app to automatically extract trace context and create server spans
FastAPIInstrumentor.instrument_app(app)

# Configuration for downstream microservice URLs
AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL", "http://auth-service:8082")
PAYMENT_SERVICE_URL = os.getenv("PAYMENT_SERVICE_URL", "http://payment-service:8083")
JAEGER_UI_URL = os.getenv("JAEGER_UI_URL", "http://localhost:16686")


# ------------------------------------------------------------------------------
# Pydantic Request & Response Models
# ------------------------------------------------------------------------------
class CartItem(BaseModel):
    item_id: str = Field(default="item-prod-101", description="Item identifier")
    name: str = Field(default="Kubernetes & SRE Handbook", description="Item name")
    unit_price: float = Field(default=49.99, ge=0.0, description="Unit price")
    quantity: int = Field(default=1, ge=1, description="Quantity")


class PaymentMethod(BaseModel):
    card_number: str = Field(default="4242-4242-4242-4242", description="Credit card number")
    cardholder_name: str = Field(default="Jane Doe", description="Cardholder name")
    expiry: str = Field(default="12/29", description="Expiration date MM/YY")
    cvv: str = Field(default="123", description="CVV security code")
    gateway: Optional[str] = Field(default="stripe_mock", description="Payment gateway backend")


class CheckoutRequest(BaseModel):
    user_token: str = Field(
        default="valid-token-user-101",
        description="User authentication token (use 'invalid-token-xyz' to simulate auth failure)",
    )
    cart_id: str = Field(default="cart-8942", description="Shopping cart identifier")
    items: List[CartItem] = Field(
        default_factory=lambda: [
            CartItem(item_id="item-101", name="Observability Handbook", unit_price=45.0, quantity=1),
            CartItem(item_id="item-202", name="SRE Swag Hoodie", unit_price=39.5, quantity=2),
        ],
        description="List of cart items",
    )
    currency: str = Field(default="USD", description="Currency code")
    payment_method: PaymentMethod = Field(default_factory=PaymentMethod, description="Payment details")
    simulate_delay_ms: int = Field(
        default=0,
        ge=0,
        le=5000,
        description="Artificial delay in milliseconds to simulate downstream latency",
    )


# ------------------------------------------------------------------------------
# Middleware: Inject Trace-ID Header into all responses
# ------------------------------------------------------------------------------
@app.middleware("http")
async def add_tracing_headers(request: Request, call_next):
    """Middleware ensuring X-Trace-ID and X-Span-ID are present in all HTTP response headers."""
    response = await call_next(request)
    trace_id = get_current_trace_id()
    span_id = get_current_span_id()
    if trace_id:
        response.headers["X-Trace-ID"] = trace_id
    if span_id:
        response.headers["X-Span-ID"] = span_id
    return response


# ------------------------------------------------------------------------------
# Routes
# ------------------------------------------------------------------------------
@app.get("/healthz", tags=["System"])
async def healthz():
    """Health check endpoint for Docker and orchestration probes."""
    return {
        "status": "healthy",
        "service": "frontend-service",
        "timestamp": time.time(),
    }


@app.get("/api/info", tags=["System"])
async def get_service_info():
    """Service metadata and tracing configuration."""
    trace_id = get_current_trace_id()
    return {
        "service": "frontend-service",
        "version": "1.0.0",
        "downstream_services": {
            "auth_service": AUTH_SERVICE_URL,
            "payment_service": PAYMENT_SERVICE_URL,
        },
        "jaeger_ui": JAEGER_UI_URL,
        "current_trace_id": trace_id,
    }


@app.post("/api/checkout", tags=["E-Commerce Operations"])
async def process_checkout(payload: CheckoutRequest):
    """
    Execute full checkout transaction across the 3-tier microservice architecture:
    1. frontend-service (processes cart & orchestrates transaction)
    2. auth-service (verifies user identity & privileges via W3C context propagation)
    3. payment-service (executes fraud check, card charge & ledger record)
    """
    order_id = f"ord-{uuid.uuid4().hex[:8]}"
    trace_id = get_current_trace_id() or "unknown"

    with tracer.start_as_current_span("frontend.process_checkout") as root_span:
        # 1. Annotate root span with high-level transaction attributes
        root_span.set_attribute("order.id", order_id)
        root_span.set_attribute("cart.id", payload.cart_id)
        root_span.set_attribute("order.currency", payload.currency)
        root_span.set_attribute("items.count", len(payload.items))

        # 2. Child Span: Cart Validation & Total Calculation
        with tracer.start_as_current_span("frontend.validate_cart") as validate_span:
            total_amount = sum(item.unit_price * item.quantity for item in payload.items)
            validate_span.set_attribute("cart.total_amount", total_amount)
            validate_span.set_attribute("cart.item_types", [i.item_id for i in payload.items])

            if total_amount <= 0:
                validate_span.set_status(StatusCode.ERROR, "Cart total amount must be greater than zero")
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Cart total must be greater than zero",
                )

            # Record event in the validation span
            validate_span.add_event(
                "cart_validated",
                {
                    "item_count": len(payload.items),
                    "total_amount": total_amount,
                    "currency": payload.currency,
                },
            )
            root_span.set_attribute("order.total_amount", total_amount)

        # 3. Child Span: Authenticate User via Auth Service (HTTP Call with W3C Context Injection)
        auth_data: Dict[str, Any] = {}
        with tracer.start_as_current_span("frontend.authenticate_user") as auth_call_span:
            auth_call_span.set_attribute("auth.target_url", f"{AUTH_SERVICE_URL}/api/verify-token")
            auth_call_span.set_attribute("auth.token_prefix", payload.user_token[:8] + "...")

            try:
                async with httpx.AsyncClient(timeout=10.0) as client:
                    # HTTPX instrumentor automatically injects W3C 'traceparent' and 'tracestate' headers
                    auth_resp = await client.post(
                        f"{AUTH_SERVICE_URL}/api/verify-token",
                        json={"token": payload.user_token},
                    )

                if auth_resp.status_code != 200:
                    error_msg = f"Auth Service rejected token: HTTP {auth_resp.status_code}"
                    auth_call_span.set_status(StatusCode.ERROR, error_msg)
                    auth_call_span.set_attribute("error.message", error_msg)
                    root_span.set_status(StatusCode.ERROR, "Checkout failed at authentication step")
                    
                    return JSONResponse(
                        status_code=status.HTTP_401_UNAUTHORIZED,
                        content={
                            "status": "FAILED",
                            "error": "Authentication failed",
                            "step": "auth-service",
                            "details": auth_resp.json() if auth_resp.headers.get("content-type") == "application/json" else auth_resp.text,
                            "trace_id": trace_id,
                            "jaeger_url": f"{JAEGER_UI_URL}/trace/{trace_id}",
                        },
                    )

                auth_data = auth_resp.json()
                user_id = auth_data.get("user_id", "unknown")
                user_tier = auth_data.get("tier", "standard")

                auth_call_span.set_attribute("user.id", user_id)
                auth_call_span.set_attribute("user.tier", user_tier)
                root_span.set_attribute("user.id", user_id)
                root_span.set_attribute("user.tier", user_tier)

                auth_call_span.add_event(
                    "auth_verified",
                    {"user_id": user_id, "tier": user_tier, "roles": ",".join(auth_data.get("roles", []))},
                )
            except httpx.RequestError as exc:
                auth_call_span.record_exception(exc)
                auth_call_span.set_status(StatusCode.ERROR, f"Auth service unreachable: {str(exc)}")
                root_span.set_status(StatusCode.ERROR, "Downstream auth service connection error")
                return JSONResponse(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    content={
                        "status": "ERROR",
                        "error": f"Auth service unreachable: {str(exc)}",
                        "trace_id": trace_id,
                    },
                )

        # 4. Child Span: Process Payment via Payment Service (HTTP Call with W3C Context Injection)
        payment_data: Dict[str, Any] = {}
        with tracer.start_as_current_span("frontend.execute_payment") as payment_call_span:
            payment_call_span.set_attribute("payment.target_url", f"{PAYMENT_SERVICE_URL}/api/charge")
            payment_call_span.set_attribute("payment.amount", total_amount)
            payment_call_span.set_attribute("payment.currency", payload.currency)

            try:
                async with httpx.AsyncClient(timeout=15.0) as client:
                    payment_resp = await client.post(
                        f"{PAYMENT_SERVICE_URL}/api/charge",
                        json={
                            "order_id": order_id,
                            "user_id": auth_data.get("user_id"),
                            "amount": total_amount,
                            "currency": payload.currency,
                            "card_number": payload.payment_method.card_number,
                            "cardholder_name": payload.payment_method.cardholder_name,
                            "expiry": payload.payment_method.expiry,
                            "gateway": payload.payment_method.gateway,
                            "simulate_delay_ms": payload.simulate_delay_ms,
                        },
                    )

                if payment_resp.status_code != 200:
                    error_msg = f"Payment Service failed: HTTP {payment_resp.status_code}"
                    payment_call_span.set_status(StatusCode.ERROR, error_msg)
                    payment_call_span.set_attribute("error.message", error_msg)
                    root_span.set_status(StatusCode.ERROR, "Checkout failed at payment step")

                    return JSONResponse(
                        status_code=payment_resp.status_code,
                        content={
                            "status": "FAILED",
                            "error": "Payment processing failed",
                            "step": "payment-service",
                            "details": payment_resp.json() if payment_resp.headers.get("content-type") == "application/json" else payment_resp.text,
                            "trace_id": trace_id,
                            "jaeger_url": f"{JAEGER_UI_URL}/trace/{trace_id}",
                        },
                    )

                payment_data = payment_resp.json()
                tx_id = payment_data.get("transaction_id", "tx_unknown")
                payment_call_span.set_attribute("payment.transaction_id", tx_id)
                payment_call_span.set_attribute("payment.status", payment_data.get("status", "SUCCESS"))
                root_span.set_attribute("payment.transaction_id", tx_id)

                payment_call_span.add_event(
                    "payment_completed",
                    {
                        "transaction_id": tx_id,
                        "gateway": payment_data.get("gateway", "stripe_mock"),
                        "status": payment_data.get("status", "SUCCESS"),
                    },
                )
            except httpx.RequestError as exc:
                payment_call_span.record_exception(exc)
                payment_call_span.set_status(StatusCode.ERROR, f"Payment service unreachable: {str(exc)}")
                root_span.set_status(StatusCode.ERROR, "Downstream payment service connection error")
                return JSONResponse(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    content={
                        "status": "ERROR",
                        "error": f"Payment service unreachable: {str(exc)}",
                        "trace_id": trace_id,
                    },
                )

        # 5. Child Span: Order Confirmation & Receipt Generation
        with tracer.start_as_current_span("frontend.finalize_order") as finalize_span:
            finalize_span.set_attribute("order.finalized", True)
            finalize_span.add_event(
                "order_confirmed",
                {
                    "order_id": order_id,
                    "items_count": len(payload.items),
                    "total_billed": total_amount,
                },
            )

        root_span.set_status(StatusCode.OK)

        return {
            "status": "SUCCESS",
            "message": "Order processed successfully across all microservices",
            "order_id": order_id,
            "cart_id": payload.cart_id,
            "total_amount": total_amount,
            "currency": payload.currency,
            "user": {
                "user_id": auth_data.get("user_id"),
                "email": auth_data.get("email"),
                "tier": auth_data.get("tier"),
            },
            "payment": {
                "transaction_id": payment_data.get("transaction_id"),
                "status": payment_data.get("status"),
                "gateway": payment_data.get("gateway"),
                "fraud_score": payment_data.get("fraud_score"),
            },
            "trace_id": trace_id,
            "jaeger_url": f"{JAEGER_UI_URL}/trace/{trace_id}",
        }
