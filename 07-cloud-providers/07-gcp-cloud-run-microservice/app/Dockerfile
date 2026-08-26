# ==============================================================================
# Dockerfile for GCP Cloud Run Scalable Microservice
# ==============================================================================
FROM python:3.12-alpine

LABEL maintainer="DevOps & SRE Projects"
LABEL description="GCP Cloud Run Scalable Microservice"

WORKDIR /app

# Install curl for health checks
RUN apk add --no-cache curl bash

# Copy application server code
COPY main.py /app/main.py

# Cloud Run runtime environment defaults
ENV PORT=8080 \
    PYTHONUNBUFFERED=1 \
    K_SERVICE="scalable-microservice" \
    K_REVISION="scalable-microservice-v1" \
    CONCURRENCY_LIMIT=80

# Expose default Cloud Run port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=3s --timeout=2s --start-period=1s --retries=3 CMD curl -fs http://localhost:8080/health || exit 1

# Start microservice
CMD ["python3", "/app/main.py"]
