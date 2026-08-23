# ==============================================================================
# Dockerfile: Centralized Fluentd Log Collector
# ==============================================================================

FROM fluent/fluentd:v1.17-1

USER root

# Create log output and buffer directories with proper permissions
RUN mkdir -p /fluentd/log /fluentd/buffer && \
    chown -R fluent:fluent /fluentd/log /fluentd/buffer

COPY config/fluent.conf /fluentd/etc/fluent.conf

USER fluent

# Port 24224: Forward protocol (TCP/UDP) for Docker logging driver
# Port 24220: HTTP monitor agent metrics
EXPOSE 24224 24224/udp 24220

ENTRYPOINT ["tini", "--", "/bin/entrypoint.sh"]
CMD ["fluentd"]
