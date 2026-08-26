# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/log-generator-app main.go

# Minimal runtime stage
FROM alpine:3.20

RUN addgroup -S -g 10001 loggergroup && \
    adduser -S -u 10001 -G loggergroup -s /sbin/nologin loggeruser

COPY --from=builder /bin/log-generator-app /usr/local/bin/log-generator-app

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/log-generator-app"]
