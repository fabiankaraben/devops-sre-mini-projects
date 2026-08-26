# ==============================================================================
# Dockerfile for High-Availability Fleet Node
# ==============================================================================
FROM python:3.12-alpine

LABEL maintainer="DevOps & SRE Projects"
LABEL description="High-Availability Auto Scaling Fleet Node"

WORKDIR /app

# Install curl for container health checks
RUN apk add --no-cache curl bash

# Copy application server script
COPY server.py /app/server.py

# Set environment defaults
ENV PORT=80 \
    INSTANCE_ID="i-local-node" \
    AVAILABILITY_ZONE="us-east-1a" \
    PYTHONUNBUFFERED=1

# Expose web service port
EXPOSE 80

# Health check
HEALTHCHECK --interval=2s --timeout=2s --start-period=1s --retries=3 CMD curl -fs http://localhost:80/health || exit 1

# Start web application
CMD ["python3", "/app/server.py", "80"]
