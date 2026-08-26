# ==============================================================================
# Dockerfile for Route 53 Failover Gateway
# ==============================================================================
FROM python:3.11-alpine

LABEL maintainer="DevOps & SRE Projects"
LABEL description="Route 53 DNS Failover Gateway and Interactive Dashboard"

WORKDIR /app

RUN apk add --no-cache curl bash

COPY failover_gateway.py /app/failover_gateway.py

ENV PORT=8080 \
    PYTHONUNBUFFERED=1

EXPOSE 8080

HEALTHCHECK --interval=2s --timeout=2s --start-period=1s --retries=3 CMD curl -fs http://localhost:8080/gateway/health || exit 1

CMD ["python3", "/app/failover_gateway.py"]
