# ==============================================================================
# Dockerfile - Prometheus Server with Remote Write Configuration
# ==============================================================================

FROM prom/prometheus:v2.51.0

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Prometheus server forwarding time-series metrics to VictoriaMetrics"

COPY prometheus.yml /etc/prometheus/prometheus.yml

EXPOSE 9090

ENTRYPOINT ["/bin/prometheus"]
CMD [ \
    "--config.file=/etc/prometheus/prometheus.yml", \
    "--storage.tsdb.path=/prometheus", \
    "--storage.tsdb.retention.time=2d", \
    "--web.enable-lifecycle" \
]
