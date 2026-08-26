# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/gateway-backend-app main.go

# Minimal runtime stage
FROM alpine:3.20

RUN addgroup -S -g 10001 gatewaygroup && \
    adduser -S -u 10001 -G gatewaygroup -s /sbin/nologin gatewayuser

COPY --from=builder /bin/gateway-backend-app /usr/local/bin/gateway-backend-app

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/gateway-backend-app"]
