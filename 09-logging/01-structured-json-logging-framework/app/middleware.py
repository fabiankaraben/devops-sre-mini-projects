"""HTTP Request Correlation & Structured Access Logging Middleware."""

import time
import uuid
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

from app.logger import (
    bind_context,
    clear_context,
    get_logger,
    set_span_id,
    set_trace_id,
)

access_logger = get_logger("app.middleware.access")


class CorrelationAndAccessLogMiddleware(BaseHTTPMiddleware):
    """Middleware that assigns distributed correlation IDs and logs structured HTTP access events."""

    async def dispatch(self, request: Request, call_next) -> Response:
        # Extract existing correlation ID or generate a fresh RFC-4122 UUID
        incoming_trace_id = (
            request.headers.get("X-Correlation-ID")
            or request.headers.get("X-Trace-ID")
            or request.headers.get("X-Request-ID")
        )

        trace_id = (
            incoming_trace_id
            if incoming_trace_id and len(incoming_trace_id.strip()) > 0
            else str(uuid.uuid4())
        )

        # Generate a unique 16-hex span ID for this request boundary
        span_id = uuid.uuid4().hex[:16]

        # Bind tracing context to async contextvars
        set_trace_id(trace_id)
        set_span_id(span_id)

        # Extract client information
        client_ip = request.client.host if request.client else "127.0.0.1"
        user_agent = request.headers.get("user-agent", "unknown")

        bind_context(
            http_method=request.method,
            http_path=request.url.path,
            client_ip=client_ip,
        )

        start_time = time.perf_counter()
        status_code = 500

        try:
            response = await call_next(request)
            status_code = response.status_code
        except Exception as exc:
            duration_ms = round((time.perf_counter() - start_time) * 1000, 3)
            http_meta = {
                "method": request.method,
                "path": request.url.path,
                "status_code": 500,
                "duration_ms": duration_ms,
                "client_ip": client_ip,
                "user_agent": user_agent,
            }
            access_logger.error(
                f"HTTP {request.method} {request.url.path} failed with unhandled exception: {str(exc)}",
                exc_info=True,
                extra={"http": http_meta},
            )
            clear_context()
            raise exc

        duration_ms = round((time.perf_counter() - start_time) * 1000, 3)

        # Attach correlation headers to response
        response.headers["X-Correlation-ID"] = trace_id
        response.headers["X-Request-ID"] = trace_id
        response.headers["X-Span-ID"] = span_id

        # Prepare HTTP metadata object adhering to log schema
        http_meta = {
            "method": request.method,
            "path": request.url.path,
            "status_code": status_code,
            "duration_ms": duration_ms,
            "client_ip": client_ip,
            "user_agent": user_agent,
        }

        # Select appropriate log level based on HTTP status code
        message = f"HTTP {request.method} {request.url.path} completed with status {status_code} in {duration_ms}ms"

        if status_code >= 500:
            access_logger.error(message, extra={"http": http_meta})
        elif status_code >= 400:
            access_logger.warning(message, extra={"http": http_meta})
        else:
            access_logger.info(message, extra={"http": http_meta})

        # Clear context after request finishes
        clear_context()

        return response
