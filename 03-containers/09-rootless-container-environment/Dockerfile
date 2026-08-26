# ==============================================================================
# Dockerfile - Rootless Container Execution & User Namespace Lab
# ==============================================================================
FROM alpine:3.20

# Install user namespace tools, shadow utilities, and diagnostics
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    shadow \
    util-linux \
    procps \
    coreutils \
    iproute2

# Create unprivileged developer user and home directory
RUN addgroup -g 1000 developer && \
    adduser -u 1000 -G developer -h /home/developer -s /bin/bash -D developer

# Configure subordinate UID and GID ranges for user namespaces
RUN echo "developer:100000:65536" > /etc/subuid && \
    echo "developer:100000:65536" > /etc/subgid

# Create sample host-owned root files to test privilege boundary protection
RUN mkdir -p /root/secret && \
    echo "TOP_SECRET_HOST_DATA_ROOT_ONLY" > /root/secret/flag.txt && \
    chmod 700 /root/secret && \
    chmod 600 /root/secret/flag.txt

# Copy scripts into lab environment
WORKDIR /home/developer
COPY setup_rootless.sh /home/developer/setup_rootless.sh
COPY verify_isolation.sh /home/developer/verify_isolation.sh

RUN chmod +x /home/developer/*.sh && \
    chown -R developer:developer /home/developer

# Default to running as unprivileged developer user
USER developer
WORKDIR /home/developer

ENTRYPOINT ["/bin/bash"]
CMD ["/home/developer/verify_isolation.sh"]
