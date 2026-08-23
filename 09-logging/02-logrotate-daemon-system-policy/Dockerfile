# ==============================================================================
# Dockerfile: Mini-Project 09-02 Logrotate Daemon System Policy
# ==============================================================================
# Provides a full Linux environment with logrotate, cron, gzip, and Python 3
# to test system-level log rotation policies, SIGHUP signals, and zero log loss.
# ==============================================================================

FROM python:3.11-slim-bookworm

LABEL maintainer="DevOps & SRE Educational Projects"
LABEL description="Linux logrotate system daemon testing environment"

# Install logrotate, gzip, cron, procps (for kill/ps)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        logrotate \
        gzip \
        cron \
        procps \
        curl \
        bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Create log, pid, and config directories
RUN mkdir -p /var/log/custom-app /var/run /etc/logrotate.d /app/config /app/daemon

# Copy logrotate configurations
COPY config/custom-app.conf /etc/logrotate.d/custom-app
COPY config/custom-app.conf /app/config/custom-app.conf
COPY config/custom-app-copytruncate.conf /app/config/custom-app-copytruncate.conf

# Logrotate enforces strict permissions: must be owned by root, permissions 0644 or 0444
RUN chown root:root /etc/logrotate.d/custom-app && \
    chmod 0644 /etc/logrotate.d/custom-app

# Copy daemon and audit verification scripts
COPY daemon/continuous_log_writer.py /app/daemon/continuous_log_writer.py
COPY verify_zero_loss.py /app/verify_zero_loss.py

RUN chmod +x /app/daemon/continuous_log_writer.py /app/verify_zero_loss.py

# Keep container active for interactive testing and automated test execution
CMD ["tail", "-f", "/dev/null"]
