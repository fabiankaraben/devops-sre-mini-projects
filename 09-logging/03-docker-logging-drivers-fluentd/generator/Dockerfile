# ==============================================================================
# Dockerfile: High-Volume Log Producer Container
# ==============================================================================

FROM python:3.11-slim

WORKDIR /app

# Create unprivileged user (UID 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /bin/bash -m appuser

COPY generator/log_generator.py /app/log_generator.py
RUN chmod +x /app/log_generator.py && chown -R appuser:appgroup /app

USER appuser

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/log_generator.py"]
CMD ["--count", "10000"]
