# ==============================================================================
# Application Dockerfile - Python FastAPI with RED & USE Instrumentation
# ==============================================================================

FROM python:3.11-slim

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="FastAPI microservice instrumented with Prometheus RED & USE metrics"

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8000 \
    MAX_WORKERS=10

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY main.py .

# Create and switch to non-root user
RUN useradd -u 10001 -m appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=3s \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
