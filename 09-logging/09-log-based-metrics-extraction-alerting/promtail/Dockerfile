FROM busybox:stable-musl AS builder

FROM grafana/promtail:2.9.8

# Copy standalone static wget binary for container health checks
COPY --from=builder /bin/busybox /bin/busybox
COPY --from=builder /bin/wget /bin/wget

COPY promtail-config.yml /etc/promtail/promtail-config.yml

EXPOSE 9080

CMD ["-config.file=/etc/promtail/promtail-config.yml"]
