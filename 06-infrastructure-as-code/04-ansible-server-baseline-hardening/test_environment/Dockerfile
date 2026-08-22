# ==============================================================================
# Dockerfile - Ephemeral Ubuntu Test Node for Ansible Hardening Audit
# ==============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install core packages needed for SSH, Ansible Python runtime, and security packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    sudo \
    python3 \
    python3-apt \
    ufw \
    fail2ban \
    iptables \
    iproute2 \
    procps \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create privilege separation directory for OpenSSH
RUN mkdir -p /var/run/sshd /var/log

# Create or configure non-root test user 'ubuntu' with sudo access
RUN (id -u ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash -u 1000 ubuntu) && \
    echo "ubuntu:ubuntu" | chpasswd && \
    echo "root:rootpassword" | chpasswd && \
    mkdir -p /etc/sudoers.d && \
    echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu && \
    chmod 0440 /etc/sudoers.d/ubuntu

# Create .ssh directory for ubuntu user
RUN mkdir -p /home/ubuntu/.ssh && \
    chmod 0700 /home/ubuntu/.ssh && \
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh

# Generate default host keys
RUN ssh-keygen -A

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose standard SSH port
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
