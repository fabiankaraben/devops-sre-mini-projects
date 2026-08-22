# ==============================================================================
# Prometheus Server Image with Application Monitoring Rules
# ==============================================================================

FROM prom/prometheus:v2.54.1

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Prometheus server configured with RED and USE monitoring rules"

COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY rules /etc/prometheus/rules

WORKDIR /prometheus
VOLUME [ "/prometheus" ]
EXPOSE 9090
