FROM python:3.11-alpine

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Site Internal App Service for Cross-VPN Traffic Simulation"

# Install networking diagnostic and traffic simulation utilities
RUN apk update && \
    apk add --no-cache \
        bash \
        iproute2 \
        curl \
        iperf3 \
        bind-tools \
        ca-certificates && \
    rm -rf /var/cache/apk/*

WORKDIR /app
COPY app/app.py /app/app.py
COPY scripts/entrypoint-app.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /app/app.py

EXPOSE 8080

HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
    CMD curl -f http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
