# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/static-diagnostics-app main.go

# Minimal runtime stage
FROM alpine:3.20

RUN addgroup -S -g 10001 staticgroup && \
    adduser -S -u 10001 -G staticgroup -s /sbin/nologin staticuser

COPY --from=builder /bin/static-diagnostics-app /usr/local/bin/static-diagnostics-app

USER 10001:10001
EXPOSE 8888

ENTRYPOINT ["/usr/local/bin/static-diagnostics-app"]
