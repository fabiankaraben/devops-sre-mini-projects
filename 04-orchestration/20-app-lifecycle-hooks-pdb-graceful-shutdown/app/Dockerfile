# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/lifecycle-app main.go

# Minimal runtime stage
FROM alpine:3.20

RUN addgroup -S -g 10001 appgroup && \
    adduser -S -u 10001 -G appgroup -s /sbin/nologin appuser && \
    mkdir -p /etc/app-init && chown -R 10001:10001 /etc/app-init

COPY --from=builder /bin/lifecycle-app /usr/local/bin/lifecycle-app

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/lifecycle-app"]
