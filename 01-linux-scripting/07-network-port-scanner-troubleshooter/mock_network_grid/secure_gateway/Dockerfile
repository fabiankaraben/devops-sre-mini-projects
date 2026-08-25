FROM alpine:3.21

# Install OpenSSH, iptables, Python, and bash
RUN apk add --no-cache openssh-server iptables bash python3 curl

# SSH Configuration
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    echo "root:password" | chpasswd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22 8443 9999

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
