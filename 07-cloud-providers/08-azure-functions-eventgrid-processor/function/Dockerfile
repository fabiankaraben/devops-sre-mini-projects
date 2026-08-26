# ==============================================================================
# Dockerfile for Azure Functions Event Grid Blob Processor
# ==============================================================================
FROM python:3.11-alpine

LABEL maintainer="DevOps & SRE Projects"
LABEL description="Azure Functions Event Grid Blob Processor"

WORKDIR /app

# Install curl for health checks
RUN apk add --no-cache curl bash

# Copy requirements and function code
COPY requirements.txt /app/requirements.txt
COPY function_app.py /app/function_app.py
COPY host.json /app/host.json

# Environment variables
ENV PORT=8080 \
    PYTHONUNBUFFERED=1 \
    COSMOS_DB_DATABASE="media-metadata" \
    COSMOS_DB_CONTAINER="blobs" \
    STORAGE_CONTAINER_NAME="images-upload"

EXPOSE 8080

# Health check
HEALTHCHECK --interval=3s --timeout=2s --start-period=1s --retries=3 CMD curl -fs http://localhost:8080/health || exit 1

# Start the function server
CMD ["python3", "/app/function_app.py"]
