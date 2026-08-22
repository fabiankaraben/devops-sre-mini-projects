# ==============================================================================
# Prometheus Image Packaging Configuration
# ==============================================================================

FROM prom/prometheus:v2.54.1

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Prometheus server for Grafana Dashboards as Code provisioning stack"

COPY prometheus.yml /etc/prometheus/prometheus.yml

WORKDIR /prometheus
VOLUME [ "/prometheus" ]
EXPOSE 9090
