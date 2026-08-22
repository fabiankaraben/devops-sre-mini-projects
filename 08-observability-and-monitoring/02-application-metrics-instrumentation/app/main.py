"""
main.py - Instrumented FastAPI Microservice exposing RED and USE Metrics

Exposes Prometheus metrics at /metrics implementing:
- RED Method: Rate (http_requests_total), Errors (5xx status counters), Duration (http_request_duration_seconds Histogram).
- USE Method: Utilization (app_worker_pool_active_workers), Saturation (app_task_queue_depth), Errors (app_resource_errors_total).
"""

import asyncio
import os
import random
import time
from typing import Optional
from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
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

# RED Method Metrics
HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests processed by endpoint and status",
    ["method", "endpoint", "status_code", "status_class"],
)

HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds",
    "HTTP request execution latency in seconds",
    ["method", "endpoint", "status_class"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

HTTP_REQUESTS_IN_FLIGHT = Gauge(
    "http_requests_in_flight",
    "Current number of concurrent HTTP requests being processed",
    ["method", "endpoint"],
)

# USE Method Metrics (Simulated Resource / Worker Pool)
MAX_WORKERS = int(os.getenv("MAX_WORKERS", "10"))

WORKER_POOL_ACTIVE = Gauge(
    "app_worker_pool_active_workers",
    "Number of worker threads currently processing background workload",
)

WORKER_POOL_MAX = Gauge(
    "app_worker_pool_max_workers",
    "Maximum configured capacity of the background worker pool",
)
WORKER_POOL_MAX.set(MAX_WORKERS)

TASK_QUEUE_DEPTH = Gauge(
    "app_task_queue_depth",
    "Current number of pending tasks waiting in the execution queue (Saturation)",
)

RESOURCE_ERRORS_TOTAL = Counter(
    "app_resource_errors_total",
    "Total internal resource pool and subsystem errors (USE Errors)",
    ["resource"],
)

# Initialize Gauges
WORKER_POOL_ACTIVE.set(0)
TASK_QUEUE_DEPTH.set(0)

# ------------------------------------------------------------------------------
# 2. FastAPI Application & Middleware
# ------------------------------------------------------------------------------

app = FastAPI(
    title="RED & USE Instrumented Microservice",
    description="Educational DevOps microservice demonstrating Prometheus RED and USE observability patterns.",
    version="1.0.0",
)

# Background task processing queue state
task_queue: asyncio.Queue = asyncio.Queue()
active_workers_count = 0
queue_lock = asyncio.Lock()


def get_status_class(status_code: int) -> str:
    """Return status class string (e.g. 2xx, 4xx, 5xx)."""
    return f"{status_code // 100}xx"


@app.middleware("http")
async def prometheus_metrics_middleware(request: Request, call_next):
    """Intercept all requests to record RED metrics: Rate, Duration, and Errors."""
    # Exclude /metrics from RED metrics to prevent self-observability distortion
    if request.url.path == "/metrics":
        return await call_next(request)

    method = request.method
    # Normalize endpoint path to avoid high cardinality
    path = request.url.path
    if path.startswith("/api/"):
        endpoint = "/" + "/".join(path.strip("/").split("/")[:2])
    else:
        endpoint = path

    HTTP_REQUESTS_IN_FLIGHT.labels(method=method, endpoint=endpoint).inc()
    start_time = time.perf_counter()

    try:
        response = await call_next(request)
        status_code = response.status_code
    except Exception as exc:
        status_code = status.HTTP_500_INTERNAL_SERVER_ERROR
        raise exc from None
    finally:
        duration = time.perf_counter() - start_time
        status_class = get_status_class(status_code)

        # Record RED metrics
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

        HTTP_REQUESTS_IN_FLIGHT.labels(method=method, endpoint=endpoint).dec()

    return response


# ------------------------------------------------------------------------------
# 3. Microservice Endpoints
# ------------------------------------------------------------------------------

@app.get("/metrics", summary="Prometheus metrics exposition endpoint")
def metrics():
    """Exposes all registered Prometheus metrics in plaintext exposition format."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/healthz", summary="Liveness & Readiness probe")
def healthz():
    """Basic health check endpoint."""
    return {"status": "ok", "service": "instrumented-api", "timestamp": time.time()}


@app.get("/api/items", summary="Fast steady-state transaction endpoint")
async def get_items(count: int = 5):
    """Simulates fast, reliable steady-state database/cache queries (5-20ms)."""
    sleep_duration = random.uniform(0.005, 0.020)
    await asyncio.sleep(sleep_duration)
    items = [{"id": i, "name": f"item-{i}", "price": round(random.uniform(10.0, 100.0), 2)} for i in range(1, count + 1)]
    return {"status": "success", "count": len(items), "data": items, "latency_s": round(sleep_duration, 4)}


@app.get("/api/slow", summary="Controllable latency injection endpoint")
async def get_slow(delay: float = 0.5, jitter: float = 0.1):
    """Simulates slow database queries or downstream microservice latencies (p95/p99 testing)."""
    actual_delay = max(0.01, delay + random.uniform(-jitter, jitter))
    await asyncio.sleep(actual_delay)
    return {
        "status": "success",
        "message": "Slow transaction completed",
        "requested_delay": delay,
        "actual_delay": round(actual_delay, 4),
    }


@app.get("/api/flaky", summary="Controllable error generation endpoint")
async def get_flaky(error_rate: float = 0.3):
    """Simulates transient server faults and 5xx errors for RED Error Rate testing."""
    if random.random() < error_rate:
        # Simulate internal server fault (500) or upstream timeout (503)
        status_code = random.choice([status.HTTP_500_INTERNAL_SERVER_ERROR, status.HTTP_503_SERVICE_UNAVAILABLE])
        raise HTTPException(status_code=status_code, detail="Simulated transient service failure")

    await asyncio.sleep(random.uniform(0.01, 0.05))
    return {"status": "success", "message": "Transaction succeeded without errors"}


class WorkloadRequest(BaseModel):
    batch_size: int = Field(default=10, ge=1, le=100, description="Number of items to process")
    task_duration: float = Field(default=0.2, ge=0.01, le=5.0, description="Simulated processing time per task in seconds")


async def background_worker(task_id: int, duration: float):
    """Simulates a background worker consuming a task, updating USE metrics."""
    global active_workers_count
    async with queue_lock:
        active_workers_count += 1
        WORKER_POOL_ACTIVE.set(active_workers_count)
        TASK_QUEUE_DEPTH.dec()

    try:
        await asyncio.sleep(duration)
    finally:
        async with queue_lock:
            active_workers_count -= 1
            WORKER_POOL_ACTIVE.set(active_workers_count)


@app.post("/api/process", summary="Simulates resource pool utilization and queue saturation (USE)")
async def process_workload(workload: WorkloadRequest):
    """
    Submits a batch of tasks to simulate thread pool utilization and queue saturation.
    Increments task_queue_depth and active_workers gauges.
    """
    TASK_QUEUE_DEPTH.inc(workload.batch_size)

    # Spawn background tasks up to batch_size
    for i in range(workload.batch_size):
        asyncio.create_task(background_worker(i, workload.task_duration))

    return {
        "status": "queued",
        "tasks_submitted": workload.batch_size,
        "max_workers": MAX_WORKERS,
        "current_active_workers": active_workers_count,
    }


class ErrorInjectionRequest(BaseModel):
    resource: str = Field(default="db_pool", description="Target resource: db_pool, thread_pool, disk_io, memory")
    count: int = Field(default=1, ge=1, le=50, description="Number of errors to record")


@app.post("/api/inject-resource-error", summary="Injects USE resource subsystem errors")
def inject_resource_error(req: ErrorInjectionRequest):
    """Increments the app_resource_errors_total counter for USE error tracking."""
    RESOURCE_ERRORS_TOTAL.labels(resource=req.resource).inc(req.count)
    return {
        "status": "injected",
        "resource": req.resource,
        "errors_injected": req.count,
    }
