# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/data-state-app main.go

# Minimal runtime stage
FROM alpine:3.20

RUN addgroup -S -g 10001 storagegroup && \
    adduser -S -u 10001 -G storagegroup -s /sbin/nologin storageuser && \
    mkdir -p /data && chown -R 10001:10001 /data

COPY --from=builder /bin/data-state-app /usr/local/bin/data-state-app

USER 10001:10001
EXPOSE 8080
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/data-state-app"]
