# ==============================================================================
# Dockerfile - Container Resource Constraints and OOM Profiler
# ==============================================================================
FROM python:3.12-slim

# Prevent Python from writing .pyc files and buffer stdout/stderr
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Create an unprivileged application user
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /bin/bash -m appuser

# Set working directory
WORKDIR /app

# Copy application script and set ownership
COPY memory_hog.py /app/memory_hog.py
RUN chmod +x /app/memory_hog.py && \
    chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Default entrypoint
ENTRYPOINT ["python3", "/app/memory_hog.py"]
CMD ["--mode=oom", "--chunk-size-mb=10", "--delay=0.5"]
