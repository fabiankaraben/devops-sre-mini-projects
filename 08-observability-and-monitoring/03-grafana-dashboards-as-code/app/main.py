"""
main.py - Live Telemetry Microservice for Grafana Dashboards as Code

Exposes RED and USE metrics at /metrics with automatic background traffic generation
to ensure Grafana dashboard panels populate with live graphs immediately.
"""

import asyncio
import os
import random
import time
from fastapi import FastAPI, HTTPException, Request, Response, status
from pydantic import BaseModel, Field
import prometheus_client
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# ------------------------------------------------------------------------------
# 1. Prometheus Metrics Definitions
# ------------------------------------------------------------------------------

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests processed by endpoint and status",
    ["method", "endpoint", "status_code", "status_class"],
)

HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "endpoint", "status_class"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

HTTP_REQUESTS_IN_FLIGHT = Gauge(
    "http_requests_in_flight",
    "Current number of concurrent HTTP requests being processed",
)

# USE Method Metrics
MAX_WORKERS = int(os.getenv("MAX_WORKERS", "10"))

WORKER_POOL_ACTIVE = Gauge(
    "app_worker_pool_active_workers",
    "Number of worker threads processing workload",
)

WORKER_POOL_MAX = Gauge(
    "app_worker_pool_max_workers",
    "Maximum capacity of the background worker pool",
)
WORKER_POOL_MAX.set(MAX_WORKERS)

TASK_QUEUE_DEPTH = Gauge(
    "app_task_queue_depth",
    "Number of pending tasks waiting in the queue",
)

RESOURCE_ERRORS_TOTAL = Counter(
    "app_resource_errors_total",
    "Total errors in internal resource subsystems",
    ["resource"],
)

WORKER_POOL_ACTIVE.set(0)
TASK_QUEUE_DEPTH.set(0)

# ------------------------------------------------------------------------------
# 2. FastAPI Application
# ------------------------------------------------------------------------------

app = FastAPI(
    title="Grafana Telemetry Producer Microservice",
    description="Provides real-time RED and USE metrics for Grafana dashboards.",
    version="1.0.0",
)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    if request.url.path == "/metrics":
        return await call_next(request)

    HTTP_REQUESTS_IN_FLIGHT.inc()
    start_time = time.perf_counter()
    method = request.method
    path = request.url.path
    endpoint = "/" + "/".join(path.strip("/").split("/")[:2]) if path.startswith("/api/") else path

    try:
        response = await call_next(request)
        status_code = response.status_code
    except Exception as exc:
        status_code = 500
        raise exc from None
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
def get_metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/healthz")
def healthz():
    return {"status": "healthy", "service": "grafana-telemetry-api"}


@app.get("/api/items")
async def get_items(count: int = 5):
    await asyncio.sleep(random.uniform(0.005, 0.025))
    return {"status": "ok", "items": [f"item-{i}" for i in range(1, count + 1)]}


@app.get("/api/slow")
async def get_slow(delay: float = 0.4):
    await asyncio.sleep(delay + random.uniform(0.01, 0.1))
    return {"status": "ok", "latency": delay}


@app.get("/api/flaky")
async def get_flaky(error_rate: float = 0.3):
    if random.random() < error_rate:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Synthetic server failure")
    await asyncio.sleep(0.02)
    return {"status": "ok"}


@app.post("/api/process")
async def process_task(tasks: int = 5, duration: float = 0.2):
    TASK_QUEUE_DEPTH.inc(tasks)
    for _ in range(tasks):
        asyncio.create_task(_run_simulated_task(duration))
    return {"status": "queued", "tasks": tasks}


async def _run_simulated_task(duration: float):
    WORKER_POOL_ACTIVE.inc()
    TASK_QUEUE_DEPTH.dec()
    try:
        await asyncio.sleep(duration)
    finally:
        WORKER_POOL_ACTIVE.dec()


# ------------------------------------------------------------------------------
# 3. Continuous Background Workload Generator (for lively dashboard rendering)
# ------------------------------------------------------------------------------
@app.on_event("startup")
async def start_background_telemetry_generator():
    """Generates continuous light traffic so Grafana dashboards show lively time-series data."""
    async def telemetry_loop():
        while True:
            try:
                # 1. Steady request
                HTTP_REQUESTS_TOTAL.labels(method="GET", endpoint="/api/items", status_code="200", status_class="2xx").inc(random.randint(2, 6))
                HTTP_REQUEST_DURATION_SECONDS.labels(method="GET", endpoint="/api/items", status_class="2xx").observe(random.uniform(0.008, 0.035))

                # 2. Occasional slow request
                if random.random() < 0.35:
                    HTTP_REQUESTS_TOTAL.labels(method="GET", endpoint="/api/slow", status_code="200", status_class="2xx").inc()
                    HTTP_REQUEST_DURATION_SECONDS.labels(method="GET", endpoint="/api/slow", status_class="2xx").observe(random.uniform(0.35, 0.85))

                # 3. Occasional error
                if random.random() < 0.20:
                    HTTP_REQUESTS_TOTAL.labels(method="GET", endpoint="/api/flaky", status_code="500", status_class="5xx").inc()
                    HTTP_REQUEST_DURATION_SECONDS.labels(method="GET", endpoint="/api/flaky", status_class="5xx").observe(random.uniform(0.02, 0.05))

                # 4. Periodic worker utilization & errors
                if random.random() < 0.25:
                    WORKER_POOL_ACTIVE.set(random.randint(1, 7))
                    TASK_QUEUE_DEPTH.set(random.randint(0, 4))
                else:
                    WORKER_POOL_ACTIVE.set(random.randint(0, 2))
                    TASK_QUEUE_DEPTH.set(0)

                if random.random() < 0.10:
                    RESOURCE_ERRORS_TOTAL.labels(resource=random.choice(["db_pool", "thread_pool"])).inc()

            except Exception:
                pass
            await asyncio.sleep(1.0)

    asyncio.create_task(telemetry_loop())
