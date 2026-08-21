# ==============================================================================
# Flaky Application Dockerfile with Native Healthcheck
# ==============================================================================
FROM python:3.12-alpine

# Create unprivileged application user
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -s /sbin/nologin -H -D appuser

WORKDIR /app

# Copy application script
COPY --chown=10001:10001 app.py .

# Switch to non-root user
USER 10001:10001

EXPOSE 8080

# Native container healthcheck probe (Fast polling for educational demo)
#   - interval: 4s (Probe every 4 seconds)
#   - timeout: 2s (Max wait time for probe response)
#   - start-period: 3s (Grace period during startup)
#   - retries: 2 (Mark UNHEALTHY after 2 consecutive failures)
HEALTHCHECK --interval=4s --timeout=2s --start-period=3s --retries=2 \
    CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["python3", "app.py"]
