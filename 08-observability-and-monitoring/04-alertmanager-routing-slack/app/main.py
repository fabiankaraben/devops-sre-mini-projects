"""
main.py - Target Application Microservice with Fault Injection

Exposes RED metrics and controllable synthetic failure injection endpoints
to trigger Prometheus Alerting Rules and Alertmanager routing pipelines.
"""

import asyncio
import os
import random
import time
from fastapi import FastAPI, HTTPException, Request, Response, status
import prometheus_client
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# ------------------------------------------------------------------------------
# 1. Prometheus Metrics
# ------------------------------------------------------------------------------

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests processed by endpoint and status",
    ["method", "endpoint", "status_code", "status_class"],
)

HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds",
    "HTTP request execution latency in seconds",
    ["method", "endpoint", "status_class"],
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0),
)

HTTP_REQUESTS_IN_FLIGHT = Gauge(
    "http_requests_in_flight",
    "Current active in-flight requests",
)

# ------------------------------------------------------------------------------
# 2. Application & Fault State
# ------------------------------------------------------------------------------

app = FastAPI(title="Target Microservice with Incident Simulation", version="1.0.0")

# Outage simulation state
is_service_crashed = False


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    # Exclude /metrics from RED metrics to prevent self-observability distortion
    if request.url.path == "/metrics":
        if is_service_crashed:
            return Response(content="Service Outage Active", status_code=500)
        return await call_next(request)

    HTTP_REQUESTS_IN_FLIGHT.inc()
    start_time = time.perf_counter()
    method = request.method
    path = request.url.path
    endpoint = "/" + "/".join(path.strip("/").split("/")[:2]) if path.startswith("/api/") else path

    try:
        if is_service_crashed and not path.endswith("/recover"):
            raise HTTPException(status_code=500, detail="Service currently crashed (simulated outage)")

        response = await call_next(request)
        status_code = response.status_code
    except HTTPException as http_exc:
        status_code = http_exc.status_code
        response = Response(content=f'{{"error": "{http_exc.detail}"}}', status_code=status_code, media_type="application/json")
    except Exception:
        status_code = 500
        response = Response(content='{"error": "Internal Server Error"}', status_code=500, media_type="application/json")
    finally:
        duration = time.perf_counter() - start_time
        status_class = f"{status_code // 100}xx"

        HTTP_REQUESTS_TOTAL.labels(
            method=method,
            endpoint=endpoint,
            status_code=str(status_code),
            status_class=status_class,
        ).inc()

        HTTP_REQUEST_DURATION_SECONDS.labels(
            method=method,
            endpoint=endpoint,
            status_class=status_class,
        ).observe(duration)

        HTTP_REQUESTS_IN_FLIGHT.dec()

    return response


@app.get("/metrics")
def metrics():
    if is_service_crashed:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Service Outage Active")
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/healthz")
def healthz():
    if is_service_crashed:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Service Outage Active")
    return {"status": "healthy", "crashed": False}


@app.get("/api/items")
async def get_items():
    await asyncio.sleep(random.uniform(0.005, 0.025))
    return {"status": "ok", "items": ["checkout-item-1", "checkout-item-2"]}


# ------------------------------------------------------------------------------
# 3. Incident Trigger Endpoints
# ------------------------------------------------------------------------------

@app.get("/api/crash")
@app.post("/api/fault/crash")
def simulate_crash():
    """Triggers ServiceDown alert by failing /healthz and /metrics."""
    global is_service_crashed
    is_service_crashed = True
    return {"status": "incident_triggered", "mode": "CRASHED", "message": "ServiceDown alert will fire in 10s"}


@app.get("/api/recover")
@app.post("/api/fault/recover")
def simulate_recovery():
    """Restores service to healthy state, auto-resolving alerts."""
    global is_service_crashed
    is_service_crashed = False
    return {"status": "recovered", "mode": "HEALTHY", "message": "Alerts will resolve automatically"}


@app.get("/api/flaky")
async def simulate_errors(error_rate: float = 0.8):
    """Triggers HighHttpErrorRate alert."""
    if random.random() < error_rate:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Simulated 500 server error")
    await asyncio.sleep(0.01)
    return {"status": "ok"}


@app.get("/api/slow")
async def simulate_slow(delay: float = 1.0):
    """Triggers SlowResponseTime alert."""
    await asyncio.sleep(delay)
    return {"status": "ok", "delay": delay}


@app.get("/api/concurrency-spike")
async def simulate_concurrency(hold_seconds: float = 3.0):
    """Holds request to simulate in-flight concurrency spike."""
    await asyncio.sleep(hold_seconds)
    return {"status": "ok"}
