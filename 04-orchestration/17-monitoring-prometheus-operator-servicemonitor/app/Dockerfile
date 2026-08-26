# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/monitored-app main.go

# Minimal runtime stage
FROM alpine:3.20

RUN addgroup -S -g 10001 monitorgroup && \
    adduser -S -u 10001 -G monitorgroup -s /sbin/nologin monitoruser

COPY --from=builder /bin/monitored-app /usr/local/bin/monitored-app

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/monitored-app"]
