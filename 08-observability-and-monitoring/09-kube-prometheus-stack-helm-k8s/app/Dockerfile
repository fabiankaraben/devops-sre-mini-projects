# ==============================================================================
# Dockerfile - Sample Instrumented Microservice (order-api)
# ==============================================================================

FROM python:3.11-slim

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Sample application emitting metrics for Kubernetes Prometheus Operator discovery"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY main.py .

# Run as non-root user
RUN useradd -u 10001 -m appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=3s \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
