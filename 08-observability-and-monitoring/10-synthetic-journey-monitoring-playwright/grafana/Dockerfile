# ==============================================================================
# Dockerfile - Pre-provisioned Grafana Instance for Synthetic Observability
# ==============================================================================

FROM grafana/grafana:10.4.0

USER root

# Copy provisioning definitions
COPY provisioning/datasources/ /etc/grafana/provisioning/datasources/
COPY provisioning/dashboards/ /etc/grafana/provisioning/dashboards/
COPY dashboards/ /etc/grafana/provisioning/dashboards/json/

RUN chown -R grafana:root /etc/grafana/provisioning

USER grafana

EXPOSE 3000
