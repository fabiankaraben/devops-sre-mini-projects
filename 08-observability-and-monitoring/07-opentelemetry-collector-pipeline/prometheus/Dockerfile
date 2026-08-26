# ==============================================================================
# Dockerfile - Prometheus Server for OpenTelemetry Collector Pipeline
# ==============================================================================

FROM prom/prometheus:v2.51.0

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Prometheus server scraping OTel Collector internal and app metrics"

COPY prometheus.yml /etc/prometheus/prometheus.yml

EXPOSE 9090

ENTRYPOINT ["/bin/prometheus"]
CMD [ \
    "--config.file=/etc/prometheus/prometheus.yml", \
    "--storage.tsdb.path=/prometheus", \
    "--storage.tsdb.retention.time=2d", \
    "--web.enable-lifecycle" \
]
