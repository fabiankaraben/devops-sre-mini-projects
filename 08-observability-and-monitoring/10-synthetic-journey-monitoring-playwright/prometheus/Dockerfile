# ==============================================================================
# Dockerfile - Prometheus Server for Synthetic Monitoring
# ==============================================================================

FROM prom/prometheus:v2.51.0

COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY alert_rules.yml /etc/prometheus/alert_rules.yml

EXPOSE 9090
