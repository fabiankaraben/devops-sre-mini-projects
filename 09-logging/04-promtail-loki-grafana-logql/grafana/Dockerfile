# ==============================================================================
# Dockerfile: Grafana with Baked Datasources and Dashboards Provisioning
# ==============================================================================

FROM grafana/grafana:11.1.0

USER root

# Create provisioning directories with proper ownership
RUN mkdir -p /etc/grafana/provisioning/datasources \
             /etc/grafana/provisioning/dashboards

COPY datasources /etc/grafana/provisioning/datasources
COPY dashboards /etc/grafana/provisioning/dashboards

RUN chown -R grafana:root /etc/grafana/provisioning

USER grafana
