# ==============================================================================
# Multi-Stage / Lightweight Production Dockerfile
# Mini-Project 09-01: Structured JSON Logging Framework
# ==============================================================================

FROM python:3.11-slim AS builder

WORKDIR /build

# Prevent bytecode generation and unbuffer stdout for real-time log streaming
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt


# ------------------------------------------------------------------------------
# Final Runtime Stage
# ------------------------------------------------------------------------------
FROM python:3.11-slim

LABEL maintainer="DevOps & SRE Educational Projects"
LABEL description="Microservice producing standardized structured JSON logs"

WORKDIR /app

# Environment configuration
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/home/appuser/.local/bin:$PATH" \
    SERVICE_NAME="order-processing-service" \
    ENVIRONMENT="production" \
    LOG_LEVEL="INFO" \
    PORT=8000

# Create dedicated unprivileged user and group (UID/GID 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /bin/bash -m appuser

# Copy installed Python packages from builder
COPY --from=builder /root/.local /home/appuser/.local

# Copy application source and schema
COPY app /app/app
COPY schema /app/schema

# Set ownership
RUN chown -R appuser:appgroup /app /home/appuser

# Switch to unprivileged user
USER appuser

# Expose HTTP service port
EXPOSE 8000

# Health check configuration using Python standard library
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=2)" || exit 1

# Start Uvicorn ASGI Server
CMD ["python", "-m", "app.main"]
