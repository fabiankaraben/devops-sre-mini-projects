"""OpenTelemetry initialization and tracing utilities for payment-service."""

import os
from typing import Optional
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.propagate import set_global_textmap
from opentelemetry.sdk.resources import (
    DEPLOYMENT_ENVIRONMENT,
    SERVICE_NAME,
    SERVICE_VERSION,
    Resource,
)
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator


def init_telemetry(service_name: str = "payment-service") -> trace.Tracer:
    """Initialize OpenTelemetry TracerProvider, OTLP exporter, and W3C propagator."""
    # Set W3C Trace Context as global propagator
    set_global_textmap(TraceContextTextMapPropagator())

    # Build semantic resource attributes
    resource = Resource.create(
        {
            SERVICE_NAME: service_name,
            SERVICE_VERSION: os.getenv("SERVICE_VERSION", "1.0.0"),
            DEPLOYMENT_ENVIRONMENT: os.getenv("ENVIRONMENT", "local-dev"),
            "host.name": os.getenv("HOSTNAME", "payment-service"),
            "service.namespace": "ecommerce-demo",
        }
    )

    provider = TracerProvider(resource=resource)

    # Resolve OTLP HTTP endpoint (Jaeger listens on port 4318 for OTLP/HTTP)
    otlp_endpoint = os.getenv(
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://jaeger:4318/v1/traces"),
    )
    if not otlp_endpoint.endswith("/v1/traces") and ":4318" in otlp_endpoint:
        otlp_endpoint = f"{otlp_endpoint.rstrip('/')}/v1/traces"

    exporter = OTLPSpanExporter(
        endpoint=otlp_endpoint,
        timeout=10,
    )

    span_processor = BatchSpanProcessor(
        exporter,
        max_queue_size=2048,
        schedule_delay_millis=200,
        max_export_batch_size=512,
    )
    provider.add_span_processor(span_processor)
    trace.set_tracer_provider(provider)

    return trace.get_tracer(service_name)


def get_current_trace_id() -> Optional[str]:
    """Retrieve the current active trace ID formatted as a 32-character hexadecimal string."""
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx.is_valid:
        return format(ctx.trace_id, "032x")
    return None


def get_current_span_id() -> Optional[str]:
    """Retrieve the current active span ID formatted as a 16-character hexadecimal string."""
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx.is_valid:
        return format(ctx.span_id, "016x")
    return None
