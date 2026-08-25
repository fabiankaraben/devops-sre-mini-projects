FROM debian:bookworm-slim

# Install system utilities, procps (sysctl), Python3, and networking tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    python3 \
    python3-minimal \
    bash \
    curl \
    jq \
    iproute2 \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy scripts, profiles, and directories
COPY sysctl_tuner.sh sysctl_tuner.py benchmark_network.sh ./
COPY profiles/ ./profiles/
COPY backups/ ./backups/

RUN chmod +x sysctl_tuner.sh sysctl_tuner.py benchmark_network.sh

CMD ["/bin/bash", "-c", "./sysctl_tuner.sh --audit --profile web --no-fail"]
