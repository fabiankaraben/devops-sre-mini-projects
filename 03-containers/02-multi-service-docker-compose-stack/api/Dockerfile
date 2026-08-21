# ==============================================================================
# Multi-Stage Minimal Python API Container
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Build & Dependency Installation
# ------------------------------------------------------------------------------
FROM python:3.12-alpine AS builder

WORKDIR /install

# Install build dependencies for C-extensions if needed
RUN apk add --no-cache gcc musl-dev libpq-dev

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ------------------------------------------------------------------------------
# Stage 2: Minimal Runtime Environment
# ------------------------------------------------------------------------------
FROM python:3.12-alpine

# Install runtime PostgreSQL client library
RUN apk add --no-cache libpq tzdata && \
    addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -s /sbin/nologin -H -D appuser

WORKDIR /app

# Copy installed python packages from builder
COPY --from=builder /install /usr/local

# Copy application source code
COPY --chown=10001:10001 app.py .

# Switch to unprivileged user
USER 10001:10001

EXPOSE 8000

# Container healthcheck
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health')" || exit 1

ENTRYPOINT ["python3", "app.py"]
