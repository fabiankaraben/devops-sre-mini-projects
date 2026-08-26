"""OpenTelemetry Traces & Metrics SDK initialization for the sample application."""

import os
from typing import Optional, Tuple
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.propagate import set_global_textmap
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import (
    DEPLOYMENT_ENVIRONMENT,
    SERVICE_NAME,
    SERVICE_VERSION,
    Resource,
)
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator


def init_telemetry(service_name: str = "sample-order-service") -> Tuple[trace.Tracer, metrics.Meter]:
    """Initialize OpenTelemetry Tracing and Metrics pipelines exporting to OTel Collector."""
    # 1. Set W3C TraceContext as the global text map propagator
    set_global_textmap(TraceContextTextMapPropagator())

    # 2. Define semantic resource attributes
    resource = Resource.create(
        {
            SERVICE_NAME: service_name,
            SERVICE_VERSION: os.getenv("SERVICE_VERSION", "1.0.0"),
            DEPLOYMENT_ENVIRONMENT: os.getenv("ENVIRONMENT", "local-dev"),
            "host.name": os.getenv("HOSTNAME", "sample-app"),
        }
    )

    # 3. Setup Tracing Pipeline
    collector_traces_url = os.getenv(
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318/v1/traces"),
    )
    if not collector_traces_url.endswith("/v1/traces") and ":4318" in collector_traces_url:
        collector_traces_url = f"{collector_traces_url.rstrip('/')}/v1/traces"

    span_exporter = OTLPSpanExporter(
        endpoint=collector_traces_url,
        timeout=10,
    )
    span_processor = BatchSpanProcessor(
        span_exporter,
        max_queue_size=2048,
        schedule_delay_millis=200,
        max_export_batch_size=512,
    )
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(span_processor)
    trace.set_tracer_provider(tracer_provider)

    # 4. Setup Metrics Pipeline
    collector_metrics_url = os.getenv(
        "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
        os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318/v1/metrics"),
    )
    if not collector_metrics_url.endswith("/v1/metrics") and ":4318" in collector_metrics_url:
        collector_metrics_url = f"{collector_metrics_url.rstrip('/')}/v1/metrics"

    metric_exporter = OTLPMetricExporter(
        endpoint=collector_metrics_url,
        timeout=10,
    )
    # Flush metrics every 1 second for responsive verification
    metric_reader = PeriodicExportingMetricReader(
        metric_exporter,
        export_interval_millis=1000,
        export_timeout_millis=5000,
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

    return trace.get_tracer(service_name), metrics.get_meter(service_name)


def get_current_trace_id() -> Optional[str]:
    """Retrieve the current active trace ID as a 32-character hexadecimal string."""
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx.is_valid:
        return format(ctx.trace_id, "032x")
    return None
