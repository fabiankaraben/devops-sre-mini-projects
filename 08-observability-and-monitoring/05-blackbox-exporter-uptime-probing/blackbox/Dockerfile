# ==============================================================================
# Prometheus Blackbox Exporter Image
# ==============================================================================

FROM prom/blackbox-exporter:v0.25.0

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Blackbox Exporter container configured with HTTP, TCP, and DNS probe modules"

COPY blackbox.yml /etc/blackbox_exporter/config.yml

EXPOSE 9115
