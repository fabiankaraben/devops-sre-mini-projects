# ==============================================================================
# Grafana Image Packaging Dashboards as Code Provisioning
# ==============================================================================

FROM grafana/grafana:11.2.0

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Grafana container with declarative datasources and dashboards as code"

# Set non-interactive anonymous admin access for seamless zero-friction local exploration
ENV GF_AUTH_ANONYMOUS_ENABLED=true \
    GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
    GF_SECURITY_ADMIN_USER=admin \
    GF_SECURITY_ADMIN_PASSWORD=admin \
    GF_USERS_ALLOW_SIGN_UP=false \
    GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/json/apps/application_red_use.json

# Copy declarative datasources and dashboards directly into provisioning directories
COPY provisioning/datasources /etc/grafana/provisioning/datasources
COPY provisioning/dashboards /etc/grafana/provisioning/dashboards

EXPOSE 3000
