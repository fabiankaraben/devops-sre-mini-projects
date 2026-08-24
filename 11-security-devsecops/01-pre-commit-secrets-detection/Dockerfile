# ==============================================================================
# Dockerfile - Pre-Commit Git Secrets Detection Suite Sandbox
# ==============================================================================
# Multi-architecture container image equipped with Git, Gitleaks,
# Yelp detect-secrets, pre-commit framework, and Python analytics tooling.
# ==============================================================================

FROM python:3.11-slim

# Prevent interactive prompts & configure Python
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PRE_COMMIT_HOME=/workspace/.pre-commit-cache

# Install system dependencies & multi-arch Gitleaks binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install multi-architecture Gitleaks release binary
ARG GITLEAKS_VERSION=8.18.4
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then GITLEAKS_ARCH="x64"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then GITLEAKS_ARCH="arm64"; \
    else GITLEAKS_ARCH="x64"; fi && \
    curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GITLEAKS_ARCH}.tar.gz" -o gitleaks.tar.gz && \
    tar -xzf gitleaks.tar.gz -C /usr/local/bin/ gitleaks && \
    chmod +x /usr/local/bin/gitleaks && \
    rm gitleaks.tar.gz

WORKDIR /workspace

# Install Python requirements (pre-commit, detect-secrets, pre-commit-hooks, pyyaml)
COPY requirements.txt /workspace/
RUN pip install --no-cache-dir -r requirements.txt

# Configure Git user identity for local sandbox commits
RUN git config --global user.email "devsecops-tester@example.com" && \
    git config --global user.name "DevSecOps Tester" && \
    git config --global init.defaultBranch main

# Copy application files and test suite
COPY . /workspace/

RUN chmod +x /workspace/secrets_analyzer.py \
             /workspace/test_secret_blocking.sh \
             /workspace/cleanup.sh

CMD ["/workspace/test_secret_blocking.sh"]
