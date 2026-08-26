# ==============================================================================
# Dockerfile - Frontend Microservice with OpenTelemetry Tracing
# ==============================================================================

FROM python:3.11-slim

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Frontend API Gateway service with OpenTelemetry distributed tracing"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY telemetry.py .
COPY main.py .

# Create and switch to non-root user for security best practices
RUN useradd -u 10001 -m appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=3s \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
