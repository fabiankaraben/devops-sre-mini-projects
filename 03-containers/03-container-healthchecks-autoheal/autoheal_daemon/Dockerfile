# ==============================================================================
# Autoheal Daemon Sidecar Container
# ==============================================================================
FROM python:3.12-alpine

WORKDIR /app

# Copy daemon script
COPY autoheal_daemon.py .

ENV PYTHONUNBUFFERED=1
ENV DOCKER_SOCKET=/var/run/docker.sock
ENV AUTOHEAL_COOLDOWN=8

ENTRYPOINT ["python3", "autoheal_daemon.py"]
