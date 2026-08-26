# ==============================================================================
# Dockerfile - Playwright Synthetic Journey Monitoring Agent
# ==============================================================================

FROM mcr.microsoft.com/playwright/python:v1.42.0-jammy

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Playwright Synthetic User Journey Monitor & Prometheus Exporter"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TARGET_APP_URL="http://target-app:8080" \
    SCREENSHOTS_DIR="/app/screenshots" \
    SCHEDULE_INTERVAL_SECONDS="15" \
    PORT=9115

WORKDIR /app

# Install Python packages
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Ensure Chromium browser is installed
RUN playwright install chromium

# Copy agent code
COPY journey_runner.py .
COPY exporter.py .

# Create screenshots directory
RUN mkdir -p /app/screenshots && chmod 777 /app/screenshots

EXPOSE 9115

HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=5s \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:9115/healthz')" || exit 1

CMD ["uvicorn", "exporter:app", "--host", "0.0.0.0", "--port", "9115"]
