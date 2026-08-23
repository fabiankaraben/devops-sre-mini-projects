# ==============================================================================
# Dockerfile: Multi-Service Log Producer
# ==============================================================================

FROM python:3.11-slim

WORKDIR /app

# Create log directory
RUN mkdir -p /var/log/apps

COPY log_producer.py /app/log_producer.py
RUN chmod +x /app/log_producer.py

ENV PYTHONUNBUFFERED=1

CMD ["python", "/app/log_producer.py", "--continuous", "--interval", "0.1"]
