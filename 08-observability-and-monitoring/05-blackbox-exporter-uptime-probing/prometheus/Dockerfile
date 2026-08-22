# ==============================================================================
# Prometheus Server Image with Blackbox Relabeling
# ==============================================================================

FROM prom/prometheus:v2.54.1

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Prometheus server configured with Blackbox Exporter relabeling and probe rules"

COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY probe_rules.yml /etc/prometheus/rules/probe_rules.yml

WORKDIR /prometheus
VOLUME [ "/prometheus" ]
EXPOSE 9090
