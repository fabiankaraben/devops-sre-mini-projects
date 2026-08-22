# ==============================================================================
# Prometheus Server Image with Alerting Rules
# ==============================================================================

FROM prom/prometheus:v2.54.1

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Prometheus server configured with Alertmanager pipeline and alert rules"

COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY alerts.yml /etc/prometheus/rules/alerts.yml

WORKDIR /prometheus
VOLUME [ "/prometheus" ]
EXPOSE 9090
