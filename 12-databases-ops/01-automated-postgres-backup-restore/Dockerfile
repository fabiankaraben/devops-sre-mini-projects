FROM python:3.11-slim

# Install system dependencies, PostgreSQL 16 client tools, jq, and bash
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    curl \
    jq \
    gzip \
    coreutils \
    bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Install python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy all project scripts
COPY . .

# Ensure scripts have execute permissions
RUN chmod +x *.sh *.py 2>/dev/null || true

ENTRYPOINT ["/bin/bash"]
