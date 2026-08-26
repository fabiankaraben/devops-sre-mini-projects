# ==============================================================================
# Dockerfile - OpenTelemetry Collector Contrib with Healthcheck Utility
# ==============================================================================

FROM otel/opentelemetry-collector-contrib:0.95.0

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="OpenTelemetry Collector Contrib with baked pipeline configuration"

# Copy busybox static wget binary for container health checks
COPY --from=busybox:musl /bin/wget /bin/wget

# Copy declarative pipeline configuration
COPY otel-collector-config.yaml /etc/otelcol-contrib/config.yaml

EXPOSE 4317 4318 8888 8889 13133 55679

ENTRYPOINT ["/otelcol-contrib"]
CMD ["--config=/etc/otelcol-contrib/config.yaml"]
