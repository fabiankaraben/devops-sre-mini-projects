# Multi-stage hardened Dockerfile for security scanning compliance
# 1. Minimal modern base image
FROM python:3.12-slim-bookworm AS base

# 2. Hardened non-root user setup (Principle of Least Privilege)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /sbin/nologin -d /app appuser

WORKDIR /app

# 3. Secure dependencies installation with wheels caching
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# 4. Copy source files with appropriate ownership
COPY --chown=appuser:appgroup app.py .

# 5. Drop root privileges
USER 10001:10001

EXPOSE 5000

# 6. Safe production execution without debug mode
CMD ["python", "app.py"]
