"""High-Cardinality Mock Metric Exporter for TSDB Long-Term Storage Benchmarking."""

import random
import time
from typing import Dict
from fastapi import FastAPI, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

app = FastAPI(
    title="High-Cardinality Mock Metrics Exporter",
    description="Generates rich multi-dimensional time series to test TSDB index compression and remote_write",
    version="1.0.0",
)

# ------------------------------------------------------------------------------
# High-Cardinality Prometheus Metric Definitions
# ------------------------------------------------------------------------------
http_requests_counter = Counter(
    "microservice_http_requests_total",
    "Total count of HTTP requests processed across microservices",
    ["service", "customer_id", "status_code", "method"],
)

iot_sensor_gauge = Gauge(
    "iot_sensor_temperature_celsius",
    "Real-time temperature telemetry from distributed IoT sensor grid",
    ["sensor_id", "location", "firmware"],
)

db_pool_gauge = Gauge(
    "db_connection_pool_active",
    "Active connections in backend database connection pools",
    ["pool_id", "database_engine"],
)

transaction_duration_hist = Histogram(
    "ecommerce_transaction_duration_seconds",
    "Transaction processing latency distribution",
    ["service", "payment_gateway"],
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

# Dimension Pools
SERVICES = ["auth", "payment", "order", "cart", "catalog", "checkout", "shipping", "notification", "inventory", "analytics"]
LOCATIONS = ["us-east", "us-west", "eu-west", "ap-south", "sa-east"]
FIRMWARES = ["v1.0.4", "v1.1.2", "v2.0.0-rc1"]
GATEWAYS = ["stripe_mock", "paypal_mock", "adyen_mock"]
DB_ENGINES = ["postgres", "mysql", "redis", "clickhouse"]


def update_metrics_batch():
    """Dynamically simulate metric increments and gauge fluctuations on every scrape."""
    # 1. Update 150 random HTTP request series
    for _ in range(150):
        svc = random.choice(SERVICES)
        cust = f"cust_{random.randint(1, 100):03d}"
        status = random.choice(["200", "200", "200", "201", "400", "404", "500"])
        method = random.choice(["GET", "POST", "PUT", "DELETE"])
        inc = random.randint(1, 10)
        http_requests_counter.labels(service=svc, customer_id=cust, status_code=status, method=method).inc(inc)

    # 2. Update 100 IoT Sensors
    for _ in range(100):
        sensor_id = f"sensor_{random.randint(1, 150):03d}"
        loc = random.choice(LOCATIONS)
        fw = random.choice(FIRMWARES)
        temp = round(random.uniform(18.5, 34.0) + (random.random() * 2.0), 2)
        iot_sensor_gauge.labels(sensor_id=sensor_id, location=loc, firmware=fw).set(temp)

    # 3. Update DB pools
    for i in range(1, 21):
        pool_id = f"pool_{i:02d}"
        engine = random.choice(DB_ENGINES)
        active = random.randint(2, 48)
        db_pool_gauge.labels(pool_id=pool_id, database_engine=engine).set(active)

    # 4. Record transaction latency histograms
    for _ in range(25):
        svc = random.choice(["checkout", "payment", "order"])
        gw = random.choice(GATEWAYS)
        latency = random.expovariate(1.0 / 0.18)
        transaction_duration_hist.labels(service=svc, payment_gateway=gw).observe(latency)


# ------------------------------------------------------------------------------
# Routes
# ------------------------------------------------------------------------------
@app.get("/healthz", tags=["System"])
async def healthz():
    """Liveness probe for Docker container."""
    return {"status": "healthy", "service": "mock-metrics-exporter", "timestamp": time.time()}


@app.get("/api/info", tags=["System"])
async def get_info():
    """Metadata about cardinality and active dimensions."""
    return {
        "service": "mock-metrics-exporter",
        "cardinality_overview": {
            "microservice_http_requests_total": len(SERVICES) * 100 * 5 * 4,
            "iot_sensor_temperature_celsius": 150 * len(LOCATIONS) * len(FIRMWARES),
            "db_connection_pool_active": 20 * len(DB_ENGINES),
        },
    }


@app.get("/metrics", tags=["Observability"])
async def metrics():
    """Expose Prometheus formatted metrics."""
    update_metrics_batch()
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
