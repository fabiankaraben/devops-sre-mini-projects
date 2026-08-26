"""Payment Microservice with OpenTelemetry Distributed Tracing & W3C Context Propagation."""

import os
import time
import uuid
from typing import Optional
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.trace import StatusCode
from pydantic import BaseModel, Field

from telemetry import get_current_span_id, get_current_trace_id, init_telemetry

# 1. Initialize OpenTelemetry Tracing
tracer = init_telemetry("payment-service")

# 2. Create FastAPI application
app = FastAPI(
    title="Payment Microservice",
    description="Payment Processing Service with OpenTelemetry W3C Distributed Context Propagation",
    version="1.0.0",
)

# 3. Instrument FastAPI app for incoming W3C header extraction & span linking
FastAPIInstrumentor.instrument_app(app)


# ------------------------------------------------------------------------------
# Request & Response Models
# ------------------------------------------------------------------------------
class ChargeRequest(BaseModel):
    order_id: str = Field(..., description="Target order identifier")
    user_id: Optional[str] = Field(default="usr-anon", description="Customer ID")
    amount: float = Field(..., gt=0.0, description="Transaction monetary amount")
    currency: str = Field(default="USD", description="Currency code")
    card_number: str = Field(
        default="4242-4242-4242-4242",
        description="Card number (ends in '4002' to trigger card decline, '9999' for fraud trigger)",
    )
    cardholder_name: Optional[str] = Field(default="Valued Customer", description="Cardholder name")
    expiry: Optional[str] = Field(default="12/29", description="Expiry date")
    gateway: Optional[str] = Field(default="stripe_mock", description="Payment gateway adapter")
    simulate_delay_ms: int = Field(
        default=0,
        ge=0,
        le=5000,
        description="Artificial delay in milliseconds to simulate network/database latency",
    )


# ------------------------------------------------------------------------------
# Middleware
# ------------------------------------------------------------------------------
@app.middleware("http")
async def add_tracing_headers(request: Request, call_next):
    """Ensure X-Trace-ID and X-Span-ID are returned in payment responses."""
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
    """Health check endpoint for Docker compose and orchestration probes."""
    return {
        "status": "healthy",
        "service": "payment-service",
        "timestamp": time.time(),
    }


@app.post("/api/charge", tags=["Payment Processing"])
async def process_charge(req: ChargeRequest):
    """
    Process payment charge transaction:
    1. Evaluates fraud risk scoring (fraud_analysis span)
    2. Dispatches authorization to external payment gateway with latency simulation (gateway_authorize span)
    3. Commits transaction to immutable payment ledger (ledger_record span)
    """
    trace_id = get_current_trace_id() or "unknown"

    with tracer.start_as_current_span("payment.process_charge") as charge_span:
        charge_span.set_attribute("payment.order_id", req.order_id)
        charge_span.set_attribute("payment.amount", req.amount)
        charge_span.set_attribute("payment.currency", req.currency)
        charge_span.set_attribute("payment.user_id", req.user_id or "anonymous")
        charge_span.set_attribute("payment.gateway", req.gateway or "stripe_mock")

        # 1. Child Span: Fraud Risk Analysis
        with tracer.start_as_current_span("payment.fraud_analysis") as fraud_span:
            fraud_span.set_attribute("fraud.engine_version", "v3.2.0")

            # Check fraud conditions (high amount or flagged card number)
            is_fraudulent = req.amount > 5000.0 or req.card_number.replace("-", "").endswith("9999")
            fraud_score = 0.96 if is_fraudulent else 0.02

            fraud_span.set_attribute("fraud.score", fraud_score)
            fraud_span.set_attribute("fraud.verdict", "REJECTED_HIGH_RISK" if is_fraudulent else "PASSED")

            if is_fraudulent:
                fraud_span.set_status(StatusCode.ERROR, "Transaction flagged as suspicious by anti-fraud engine")
                fraud_span.add_event(
                    "fraud_flag_raised",
                    {"score": fraud_score, "rule": "MAX_AMOUNT_EXCEEDED_OR_BLACKLISTED_CARD"},
                )
                charge_span.set_status(StatusCode.ERROR, "Payment blocked by fraud detection")
                return JSONResponse(
                    status_code=status.HTTP_403_FORBIDDEN,
                    content={
                        "status": "REJECTED",
                        "error": "Payment blocked by anti-fraud protection",
                        "fraud_score": fraud_score,
                        "trace_id": trace_id,
                    },
                )

            fraud_span.add_event("fraud_check_passed", {"score": fraud_score})

        # 2. Child Span: Payment Gateway Authorization (External API Simulation)
        with tracer.start_as_current_span("payment.gateway_authorize") as gateway_span:
            gateway_span.set_attribute("gateway.name", req.gateway or "stripe_mock")
            gateway_span.set_attribute("gateway.endpoint", "https://api.gateway.mock/v1/charges")

            # Artificial Latency Simulation (demonstrates waterfall timing in Jaeger UI)
            if req.simulate_delay_ms > 0:
                gateway_span.set_attribute("simulation.artificial_delay_ms", req.simulate_delay_ms)
                time.sleep(req.simulate_delay_ms / 1000.0)

            # Check simulated card decline (card ending in 4002 or specific decline amount 9999.0)
            cleaned_card = req.card_number.replace("-", "").replace(" ", "")
            if cleaned_card.endswith("4002") or req.amount == 9999.0:
                error_reason = "Card declined: INSUFFICIENT_FUNDS_OR_CARD_EXPIRED"
                gateway_span.set_status(StatusCode.ERROR, error_reason)
                gateway_span.record_exception(
                    Exception("Card issuer rejected authorization code: 51 (Insufficient Funds)")
                )
                gateway_span.add_event(
                    "gateway_declined",
                    {"code": "51", "reason": "Insufficient Funds", "card_last4": cleaned_card[-4:]},
                )
                charge_span.set_status(StatusCode.ERROR, "Gateway authorization failed")
                return JSONResponse(
                    status_code=status.HTTP_402_PAYMENT_REQUIRED,
                    content={
                        "status": "DECLINED",
                        "error": "Card declined by issuing bank (Insufficient funds)",
                        "gateway": req.gateway,
                        "trace_id": trace_id,
                    },
                )

            gateway_span.add_event(
                "gateway_authorized",
                {"auth_code": "AUTH_OK_9921", "amount": req.amount, "currency": req.currency},
            )

        # 3. Child Span: Transaction Ledger Commit (Database Write Simulation)
        tx_id = f"tx-{uuid.uuid4().hex[:12]}"
        with tracer.start_as_current_span("payment.ledger_record") as ledger_span:
            ledger_span.set_attribute("db.system", "postgresql")
            ledger_span.set_attribute("db.name", "financial_ledger")
            ledger_span.set_attribute(
                "db.statement",
                "INSERT INTO payments (id, order_id, amount, currency, status) VALUES ($1, $2, $3, $4, $5)",
            )
            ledger_span.set_attribute("db.operation", "INSERT")
            ledger_span.set_attribute("ledger.transaction_id", tx_id)

            # Simulated small storage latency
            time.sleep(0.008)

            ledger_span.add_event("ledger_committed", {"transaction_id": tx_id, "amount": req.amount})

        charge_span.set_attribute("payment.transaction_id", tx_id)
        charge_span.set_status(StatusCode.OK)

        return {
            "status": "SUCCESS",
            "transaction_id": tx_id,
            "order_id": req.order_id,
            "amount": req.amount,
            "currency": req.currency,
            "gateway": req.gateway or "stripe_mock",
            "fraud_score": fraud_score,
            "trace_id": trace_id,
        }
