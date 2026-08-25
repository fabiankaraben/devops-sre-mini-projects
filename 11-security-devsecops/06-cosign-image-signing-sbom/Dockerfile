# ==============================================================================
# Multi-Stage Hardened Dockerfile for Secure Microservice
# ==============================================================================
# Stage 1: Dependency Builder
# ==============================================================================
FROM python:3.11-alpine AS builder

WORKDIR /build

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# ==============================================================================
# Stage 2: Minimal Distroless/Hardened Runtime
# ==============================================================================
FROM python:3.11-alpine

# Set security and OCI metadata labels
LABEL org.opencontainers.image.title="secure-payment-gateway" \
      org.opencontainers.image.description="Demonstration microservice for Cosign image signing and Syft SBOM generation" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.authors="devsecops-team@example.com" \
      org.opencontainers.image.vendor="DevOps SRE Mini Projects" \
      org.opencontainers.image.licenses="Apache-2.0"

# Create non-privileged system user and group
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S appuser -G appgroup

WORKDIR /app

# Copy installed Python packages from builder stage
COPY --from=builder /root/.local /home/appuser/.local
COPY app/ /app/

# Set ownership and permissions
RUN chown -R appuser:appgroup /app /home/appuser

ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

USER 10001:10001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

ENTRYPOINT ["python3", "/app/app.py"]
