# ==============================================================================
# Dockerfile for CoreDNS Internal DNS Server
# ==============================================================================
FROM coredns/coredns:latest

LABEL maintainer="DevOps & SRE Educational Projects"
LABEL description="CoreDNS Internal DNS Server with authoritative split-horizon zones and recursive forwarding"

# Copy Corefile configuration and zone files
COPY Corefile /etc/coredns/Corefile
COPY zones/ /etc/coredns/zones/

# Expose standard DNS ports (UDP/TCP 53), Health (8080), Readiness (8181), and Prometheus Metrics (9153)
EXPOSE 53/udp 53/tcp 8080 8181 9153

ENTRYPOINT ["/coredns"]
CMD ["-conf", "/etc/coredns/Corefile"]
