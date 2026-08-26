# ==============================================================================
# Dockerfile for Regional Multi-Region Application Instance
# ==============================================================================
FROM python:3.11-alpine

LABEL maintainer="DevOps & SRE Projects"
LABEL description="Multi-Region Active-Passive Regional Workload"

WORKDIR /app

RUN apk add --no-cache curl bash

COPY main.py /app/main.py

ENV PORT=8080 \
    PYTHONUNBUFFERED=1 \
    REGION_NAME="us-east-1" \
    REGION_ROLE="PRIMARY"

EXPOSE 8080

HEALTHCHECK --interval=3s --timeout=2s --start-period=1s --retries=3 CMD curl -fs http://localhost:8080/health || exit 1

CMD ["python3", "/app/main.py"]
