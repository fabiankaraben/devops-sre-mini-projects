# ==============================================================================
# Dockerfile - Self-Contained Multi-Engine IaC Security Scanner Sandbox
# ==============================================================================
# Packages Python, Checkov, tfsec, Terraform tools, and compliance reporting
# ==============================================================================

FROM python:3.11-alpine

LABEL maintainer="DevSecOps SRE Team" \
      description="IaC Security Scanning Sandbox with Checkov & tfsec" \
      version="1.0.0"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    CHECK_OUTPUT=cli

WORKDIR /workspace

# Install system utilities, bash, git, curl, and build dependencies
RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache bash curl jq git libffi-dev gcc musl-dev && \
    pip install --no-cache-dir checkov>=3.2.0 pyyaml>=6.0.1 && \
    rm -rf /var/cache/apk/* /root/.cache

# Copy project files
COPY . /workspace

RUN chmod +x /workspace/*.sh /workspace/*.py || true

ENTRYPOINT ["/bin/bash"]
CMD ["./iac_security_audit.sh", "--target", "all"]
