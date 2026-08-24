FROM python:3.11.8-alpine3.19

LABEL maintainer="DevOps SRE Team"
LABEL description="Payment Service Microservice consuming Vault Sidecar Injected Secrets"

WORKDIR /app

RUN addgroup -g 10001 appgroup && \
    adduser -u 10001 -G appgroup -s /bin/sh -D appuser && \
    mkdir -p /vault/secrets && \
    chown -R appuser:appgroup /app /vault/secrets

COPY --chown=appuser:appgroup app.py /app/app.py

USER 10001:10001

EXPOSE 8080

HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

ENTRYPOINT ["python3", "-u", "/app/app.py"]
