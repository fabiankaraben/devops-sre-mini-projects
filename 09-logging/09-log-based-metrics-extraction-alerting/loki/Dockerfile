FROM grafana/loki:2.9.8

# Copy configuration and rules
COPY loki-config.yml /etc/loki/local-config.yaml
COPY rules/ /etc/loki/rules/

EXPOSE 3100 9096

CMD ["-config.file=/etc/loki/local-config.yaml"]
