FROM python:3.11-slim

WORKDIR /app

# Set non-interactive and unbuffered python output
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source scripts and configuration
COPY mock_prometheus_metrics.py .
COPY slo_calculator.py .
COPY slo_config.yaml .

# Expose metrics port for mock service
EXPOSE 8080

# Default entrypoint runs the mock metrics generator
ENTRYPOINT ["python3", "mock_prometheus_metrics.py"]
