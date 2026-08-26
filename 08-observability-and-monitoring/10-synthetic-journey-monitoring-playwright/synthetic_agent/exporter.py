"""Prometheus Exporter Daemon for Synthetic Playwright User Journeys."""

import asyncio
import os
import time
from typing import Dict, List, Optional
from fastapi import FastAPI, HTTPException, Response, status
from fastapi.responses import FileResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from journey_runner import SyntheticCheckoutJourney

app = FastAPI(
    title="Synthetic Journey Prometheus Exporter",
    description="Daemon running headless Playwright user journeys and exposing Prometheus metrics",
    version="1.0.0",
)

SCREENSHOTS_DIR = os.getenv("SCREENSHOTS_DIR", "/app/screenshots")
SCHEDULE_INTERVAL_SECONDS = int(os.getenv("SCHEDULE_INTERVAL_SECONDS", "15"))

# ------------------------------------------------------------------------------
# Prometheus Metric Instruments
# ------------------------------------------------------------------------------
journey_duration_hist = Histogram(
    "synthetic_journey_duration_seconds",
    "Total duration of synthetic user journey execution in seconds",
    ["journey", "status"],
    buckets=(0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 12.0),
)

step_duration_hist = Histogram(
    "synthetic_step_duration_seconds",
    "Execution duration of individual journey steps in seconds",
    ["journey", "step", "status"],
    buckets=(0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.5, 5.0),
)

journey_runs_counter = Counter(
    "synthetic_journey_runs_total",
    "Total count of synthetic journey executions",
    ["journey", "status"],
)

step_failures_counter = Counter(
    "synthetic_step_failures_total",
    "Total count of step failures encountered in synthetic journeys",
    ["journey", "step"],
)

journey_last_success_gauge = Gauge(
    "synthetic_journey_last_success_timestamp",
    "Unix timestamp of the most recent successful synthetic journey",
    ["journey"],
)

journey_up_gauge = Gauge(
    "synthetic_journey_up",
    "Binary health status of the synthetic user journey (1 = healthy/success, 0 = broken/failed)",
    ["journey"],
)

# Initialize initial gauges
journey_up_gauge.labels(journey="checkout_flow").set(1)

LAST_EXECUTION_RESULT: Dict = {}
RUNNER_LOCK = asyncio.Lock()


async def run_journey_and_record() -> Dict:
    """Runs the checkout journey, records all Prometheus metrics, and stores the latest result."""
    global LAST_EXECUTION_RESULT

    async with RUNNER_LOCK:
        journey = SyntheticCheckoutJourney()
        result = await journey.execute()
        journey_name = result["journey"]
        status_label = "success" if result["success"] else "failed"

        # Record total journey duration
        journey_duration_hist.labels(journey=journey_name, status=status_label).observe(
            result["total_duration_seconds"]
        )
        journey_runs_counter.labels(journey=journey_name, status=status_label).inc()

        # Record step durations
        for step_name, step_time in result.get("steps", {}).items():
            step_status = "failed" if (not result["success"] and result.get("failed_step") == step_name) else "success"
            step_duration_hist.labels(journey=journey_name, step=step_name, status=step_status).observe(step_time)

        if result["success"]:
            journey_up_gauge.labels(journey=journey_name).set(1)
            journey_last_success_gauge.labels(journey=journey_name).set(time.time())
        else:
            journey_up_gauge.labels(journey=journey_name).set(0)
            failed_step = result.get("failed_step", "unknown")
            step_failures_counter.labels(journey=journey_name, step=failed_step).inc()

        LAST_EXECUTION_RESULT = result
        return result


# ------------------------------------------------------------------------------
# Background Periodic Scheduler Task
# ------------------------------------------------------------------------------
async def background_journey_scheduler():
    """Runs the synthetic journey on a continuous schedule."""
    # Warmup delay for target container initialization
    await asyncio.sleep(4)
    while True:
        try:
            await run_journey_and_record()
        except Exception as exc:
            print(f"[Scheduler] Error in synthetic runner loop: {exc}")
        await asyncio.sleep(SCHEDULE_INTERVAL_SECONDS)


@app.on_event("startup")
async def startup_event():
    os.makedirs(SCREENSHOTS_DIR, exist_ok=True)
    asyncio.create_task(background_journey_scheduler())


# ------------------------------------------------------------------------------
# API Endpoints
# ------------------------------------------------------------------------------
@app.get("/metrics", tags=["Observability"])
async def metrics():
    """Prometheus exposition endpoint."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/run", tags=["Synthetic Probes"])
async def trigger_journey():
    """Immediately trigger a synchronous synthetic journey run and return telemetry data."""
    result = await run_journey_and_record()
    return result


@app.get("/status", tags=["Synthetic Probes"])
async def get_status():
    """Returns the most recent execution result."""
    return LAST_EXECUTION_RESULT or {"status": "initializing"}


@app.get("/healthz", tags=["System"])
async def healthz():
    return {"status": "healthy", "service": "synthetic-agent", "timestamp": time.time()}


@app.get("/screenshots", tags=["Diagnostics"])
async def list_screenshots():
    """List all failure screenshots."""
    if not os.path.exists(SCREENSHOTS_DIR):
        return {"screenshots": []}
    files = sorted(
        [f for f in os.listdir(SCREENSHOTS_DIR) if f.endswith(".png")],
        reverse=True,
    )
    return {
        "count": len(files),
        "screenshots": [
            {
                "filename": f,
                "url": f"/screenshots/{f}",
                "size_bytes": os.path.getsize(os.path.join(SCREENSHOTS_DIR, f)),
            }
            for f in files
        ],
    }


@app.get("/screenshots/{filename}", tags=["Diagnostics"])
async def get_screenshot(filename: str):
    """Serve a specific failure screenshot."""
    file_path = os.path.join(SCREENSHOTS_DIR, filename)
    if not os.path.isfile(file_path):
        raise HTTPException(status_code=404, detail="Screenshot not found")
    return FileResponse(file_path, media_type="image/png")
