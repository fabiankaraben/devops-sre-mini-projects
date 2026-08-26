# ==============================================================================
# Dockerfile for Cloud Cost Governance & Tag Compliance Engine
# ==============================================================================
FROM python:3.11-alpine

LABEL maintainer="DevOps & SRE Projects"
LABEL description="Cloud Cost Governance and Tag Compliance Engine"

WORKDIR /app

# Install curl for health probes
RUN apk add --no-cache curl bash

# Copy application files
COPY requirements.txt /app/requirements.txt
COPY lambda_function.py /app/lambda_function.py

# Environment defaults
ENV PORT=8080 \
    PYTHONUNBUFFERED=1 \
    MANDATORY_TAGS="Environment,Owner,CostCenter,Project" \
    ALLOWED_ENVIRONMENTS="production,staging,development,sandbox" \
    ENABLE_AUTO_REMEDIATION="true" \
    GRACE_PERIOD_DAYS="7"

EXPOSE 8080

# Health check
HEALTHCHECK --interval=3s --timeout=2s --start-period=1s --retries=3 CMD curl -fs http://localhost:8080/health || exit 1

# Start standalone governance server
CMD ["python3", "/app/lambda_function.py", "8080"]
