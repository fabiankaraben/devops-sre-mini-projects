# ==============================================================================
# Dockerfile: Ansible Dynamic Inventory Test Node
# Lightweight, containerized simulated fleet node for local IaC testing
# ==============================================================================
FROM python:3.12-alpine

# Metadata labels for baseline container identification
LABEL maintainer="DevOps SRE Mini Projects"
LABEL description="Simulated cloud fleet target node for Ansible Dynamic Inventory testing"
LABEL devops.fleet="ansible-dynamic-inventory"

# Install runtime utilities needed for Ansible direct execution and health checking
RUN apk add --no-cache \
    bash \
    curl \
    ca-certificates \
    tzdata \
    procps \
    && ln -sf /usr/local/bin/python3 /usr/bin/python3 \
    && ln -sf /usr/local/bin/python /usr/bin/python \
    && mkdir -p /tmp/.ansible-tmp /app/.ansible/tmp /root/.ansible/tmp \
    && chmod 777 /tmp/.ansible-tmp

WORKDIR /app

# Copy application server and entrypoint script
COPY app.py /app/app.py
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /app/app.py

# Default environment variables
ENV APP_PORT=8080 \
    FLEET_ENVIRONMENT=production \
    FLEET_ROLE=web \
    FLEET_APP=frontend \
    FLEET_VERSION=1.0.0 \
    PYTHONUNBUFFERED=1

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
