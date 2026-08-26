"""Auth Microservice with OpenTelemetry Distributed Tracing & W3C Context Propagation."""

import os
import time
from typing import List, Optional
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.trace import StatusCode
from pydantic import BaseModel, Field

from telemetry import get_current_span_id, get_current_trace_id, init_telemetry

# 1. Initialize OpenTelemetry Tracing
tracer = init_telemetry("auth-service")

# 2. Create FastAPI application
app = FastAPI(
    title="Auth Microservice",
    description="Authentication & Authorization Service with OpenTelemetry W3C Distributed Context Propagation",
    version="1.0.0",
)

# 3. Instrument FastAPI app for automatic incoming W3C header extraction & span linking
FastAPIInstrumentor.instrument_app(app)


# ------------------------------------------------------------------------------
# Request & Response Models
# ------------------------------------------------------------------------------
class TokenVerificationRequest(BaseModel):
    token: str = Field(
        ...,
        description="JWT or bearer token. Use 'invalid-token-xyz' or 'expired-token' to trigger auth failure",
    )


class LoginRequest(BaseModel):
    username: str = Field(default="devops_user", description="User login handle")
    password: str = Field(default="SRE_Master_2026!", description="User password")


# ------------------------------------------------------------------------------
# Middleware
# ------------------------------------------------------------------------------
@app.middleware("http")
async def add_tracing_headers(request: Request, call_next):
    """Ensure X-Trace-ID and X-Span-ID are propagated back to the caller."""
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
    """Healthcheck endpoint for orchestrator and Docker compose probes."""
    return {
        "status": "healthy",
        "service": "auth-service",
        "timestamp": time.time(),
    }


@app.post("/api/verify-token", tags=["Authentication"])
async def verify_token(req: TokenVerificationRequest):
    """
    Verify bearer token validity and extract user claims.
    Demonstrates child spans, DB lookup simulation, attributes, events, and error recording.
    """
    trace_id = get_current_trace_id() or "unknown"

    with tracer.start_as_current_span("auth.verify_token") as verify_span:
        verify_span.set_attribute("auth.method", "bearer_jwt")
        verify_span.set_attribute("auth.token_length", len(req.token))

        # 1. Child Span: Signature & Expiration Check
        with tracer.start_as_current_span("auth.validate_jwt_signature") as jwt_span:
            jwt_span.set_attribute("jwt.algorithm", "HS256")
            jwt_span.set_attribute("jwt.issuer", "https://auth.internal")

            # Check for simulated rejection tokens
            if "invalid" in req.token.lower() or "bad" in req.token.lower():
                jwt_span.set_status(StatusCode.ERROR, "Invalid cryptographic token signature")
                jwt_span.add_event(
                    "token_validation_failed",
                    {"reason": "INVALID_SIGNATURE", "token_preview": req.token[:12]},
                )
                verify_span.set_status(StatusCode.ERROR, "Token signature verification failed")
                return JSONResponse(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    content={
                        "valid": False,
                        "error": "Invalid token signature",
                        "trace_id": trace_id,
                    },
                )

            if "expired" in req.token.lower():
                jwt_span.set_status(StatusCode.ERROR, "Token expiration threshold exceeded (exp in past)")
                jwt_span.add_event("token_expired", {"expired_at": time.time() - 3600})
                verify_span.set_status(StatusCode.ERROR, "Token is expired")
                return JSONResponse(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    content={
                        "valid": False,
                        "error": "Token has expired",
                        "trace_id": trace_id,
                    },
                )

            jwt_span.add_event("token_signature_valid", {"verified_by": "crypto-engine-v1"})

        # 2. Child Span: Mock Database Query for User Profile
        with tracer.start_as_current_span("auth.db_lookup_user") as db_span:
            db_span.set_attribute("db.system", "postgresql")
            db_span.set_attribute("db.name", "identity_prod")
            db_span.set_attribute("db.statement", "SELECT id, email, tier, roles FROM users WHERE token_hash = $1")
            db_span.set_attribute("db.operation", "SELECT")

            # Simulated lightweight query latency
            time.sleep(0.01)

            user_id = "usr-8921"
            email = "devops.engineer@example.com"
            tier = "gold" if "gold" in req.token.lower() else "standard"
            roles = ["customer", "checkout_allowed", "order_history"]

            db_span.set_attribute("user.id", user_id)
            db_span.set_attribute("user.email", email)
            db_span.add_event("user_record_retrieved", {"user_id": user_id, "rows_returned": 1})

        # 3. Child Span: Permission Policy Evaluation
        with tracer.start_as_current_span("auth.check_permissions") as rbac_span:
            rbac_span.set_attribute("rbac.policy_version", "2026.1")
            rbac_span.set_attribute("rbac.required_role", "checkout_allowed")
            rbac_span.set_attribute("rbac.granted", True)
            rbac_span.add_event("permissions_granted", {"roles": ",".join(roles)})

        verify_span.set_attribute("user.id", user_id)
        verify_span.set_attribute("user.tier", tier)
        verify_span.set_status(StatusCode.OK)

        return {
            "valid": True,
            "user_id": user_id,
            "email": email,
            "tier": tier,
            "roles": roles,
            "trace_id": trace_id,
        }


@app.post("/api/login", tags=["Authentication"])
async def login(req: LoginRequest):
    """Generate authentication token for test simulations."""
    with tracer.start_as_current_span("auth.login") as span:
        span.set_attribute("auth.username", req.username)
        token = f"valid-token-{req.username}-{int(time.time())}"
        span.add_event("login_successful", {"username": req.username})
        return {
            "status": "SUCCESS",
            "token": token,
            "expires_in": 3600,
            "token_type": "Bearer",
        }
