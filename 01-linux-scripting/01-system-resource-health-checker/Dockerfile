# Use lightweight Ubuntu LTS image for full /proc subsystem support
FROM ubuntu:24.04

# Prevent interactive prompts during apt installation
ENV DEBIAN_FRONTEND=noninteractive

# Install core utilities needed for system health monitoring and testing
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    coreutils \
    procps \
    gawk \
    jq \
    bc \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Copy scripts into container
COPY health_check.sh stress_simulator.sh test_health_check.sh ./

# Ensure executable permissions
RUN chmod +x health_check.sh stress_simulator.sh test_health_check.sh

# Default command runs health check with pretty JSON
ENTRYPOINT ["./health_check.sh"]
CMD ["--pretty"]
