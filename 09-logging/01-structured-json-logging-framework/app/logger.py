"""Enterprise Structured JSON Logging Engine with Context Propagation."""

import contextvars
import datetime
import json
import logging
import os
import sys
import traceback
from typing import Any, Dict, Optional
from app.config import settings

# ------------------------------------------------------------------------------
# Asynchronous Context Variables for Distributed Tracing & Correlation
# ------------------------------------------------------------------------------
trace_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar(
    "trace_id", default="00000000-0000-0000-0000-000000000000"
)
span_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar(
    "span_id", default="0000000000000000"
)
extra_ctx: contextvars.ContextVar[Dict[str, Any]] = contextvars.ContextVar(
    "extra_ctx", default={}
)


def get_trace_id() -> str:
    """Retrieve the active trace / correlation ID from context."""
    return trace_id_ctx.get()


def set_trace_id(trace_id: str) -> None:
    """Set the active trace / correlation ID in context."""
    trace_id_ctx.set(trace_id)


def get_span_id() -> str:
    """Retrieve the active span ID from context."""
    return span_id_ctx.get()


def set_span_id(span_id: str) -> None:
    """Set the active span ID in context."""
    span_id_ctx.set(span_id)


def bind_context(**kwargs: Any) -> None:
    """Bind additional key-value metadata to the active asynchronous context."""
    current = extra_ctx.get().copy()
    current.update(kwargs)
    extra_ctx.set(current)


def clear_context() -> None:
    """Reset the asynchronous logging context."""
    trace_id_ctx.set("00000000-0000-0000-0000-000000000000")
    span_id_ctx.set("0000000000000000")
    extra_ctx.set({})


# ------------------------------------------------------------------------------
# JSON Serialization Formatter
# ------------------------------------------------------------------------------
class StructuredJSONFormatter(logging.Formatter):
    """Formatter that outputs structured NDJSON adhering to the enterprise log schema."""

    # Standard Python LogRecord attributes to exclude from user context
    RESERVED_ATTRS = {
        "args",
        "asctime",
        "created",
        "exc_info",
        "exc_text",
        "filename",
        "funcName",
        "levelname",
        "levelno",
        "lineno",
        "module",
        "msecs",
        "msg",
        "name",
        "pathname",
        "process",
        "processName",
        "relativeCreated",
        "stack_info",
        "thread",
        "threadName",
        "http",
        "error",
        "context",
        "trace_id",
        "span_id",
    }

    def __init__(
        self,
        service_name: Optional[str] = None,
        environment: Optional[str] = None,
    ):
        super().__init__()
        self.service_name = service_name or settings.service_name
        self.environment = environment or settings.environment

    def format(self, record: logging.LogRecord) -> str:
        """Format a single log record into a valid structured JSON string."""
        now = datetime.datetime.now(datetime.timezone.utc)
        iso_timestamp = now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

        # Determine normalized log level
        level = record.levelname.upper()
        if level == "WARN":
            level = "WARNING"

        # Extract caller metadata
        caller_file = (
            os.path.basename(record.pathname)
            if record.pathname
            else record.filename or "unknown"
        )
        caller_info = {
            "file": caller_file,
            "line": int(record.lineno) if record.lineno is not None else 1,
            "func": record.funcName or "unknown",
        }

        # Retrieve correlation & trace metadata
        record_trace_id = getattr(record, "trace_id", None) or get_trace_id()
        record_span_id = getattr(record, "span_id", None) or get_span_id()

        # Build context dictionary
        context_data: Dict[str, Any] = extra_ctx.get().copy()

        # Merge record extra fields into context
        for key, value in record.__dict__.items():
            if key not in self.RESERVED_ATTRS and not key.startswith("_"):
                context_data[key] = value

        # Explicit context passed via extra={'context': {...}}
        if hasattr(record, "context") and isinstance(record.context, dict):
            context_data.update(record.context)

        # Base log event payload adhering to JSON Schema
        log_event: Dict[str, Any] = {
            "timestamp": iso_timestamp,
            "level": level,
            "logger": record.name,
            "message": record.getMessage(),
            "service": self.service_name,
            "environment": self.environment,
            "trace_id": str(record_trace_id),
            "span_id": str(record_span_id),
            "caller": caller_info,
            "context": context_data,
        }

        # Optional HTTP metadata payload
        if hasattr(record, "http") and isinstance(record.http, dict):
            log_event["http"] = record.http

        # Structured Exception / Error Handling
        if record.exc_info:
            exc_type, exc_value, exc_traceback = record.exc_info
            error_data: Dict[str, Any] = {
                "type": exc_type.__name__ if exc_type else "Exception",
                "message": str(exc_value) if exc_value else "",
                "stacktrace": traceback.format_exception(
                    exc_type, exc_value, exc_traceback
                ),
            }
            if hasattr(exc_value, "code"):
                error_data["code"] = getattr(exc_value, "code")
            log_event["error"] = error_data
        elif hasattr(record, "error") and isinstance(record.error, dict):
            log_event["error"] = record.error

        return json.dumps(log_event, default=str, ensure_ascii=False)


# ------------------------------------------------------------------------------
# Logging Initialization & Handler Configuration
# ------------------------------------------------------------------------------
def setup_logging() -> None:
    """Initialize structured logging across the entire Python process and libraries."""
    log_level = getattr(logging, settings.log_level, logging.INFO)

    formatter = StructuredJSONFormatter(
        service_name=settings.service_name,
        environment=settings.environment,
    )

    # Standard stdout stream handler
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    stream_handler.setLevel(log_level)

    # Configure root logger
    root_logger = logging.getLogger()
    root_logger.setLevel(log_level)
    root_logger.handlers.clear()
    root_logger.addHandler(stream_handler)

    # Intercept third-party loggers and route through JSON formatter
    for logger_name in (
        "uvicorn",
        "uvicorn.access",
        "uvicorn.error",
        "fastapi",
        "app",
    ):
        target_logger = logging.getLogger(logger_name)
        target_logger.setLevel(log_level)
        target_logger.handlers.clear()
        target_logger.addHandler(stream_handler)
        target_logger.propagate = False


def get_logger(name: str = "app") -> logging.Logger:
    """Obtain a named logger instance configured for structured JSON output."""
    return logging.getLogger(name)
