# ==============================================================================
# Prometheus Server Container Image
# ==============================================================================
# Base image: Official Prometheus v2.54.1
# Packages the custom prometheus.yml scrape config and recording/alerting rules.
# ==============================================================================

FROM prom/prometheus:v2.54.1

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Prometheus server configured for Node Exporter host monitoring"

# Copy custom Prometheus configuration and rules
COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY rules /etc/prometheus/rules

# Set working directory
WORKDIR /prometheus

# Prometheus TSDB volume mount point
VOLUME [ "/prometheus" ]

# Default Prometheus web port
EXPOSE 9090
