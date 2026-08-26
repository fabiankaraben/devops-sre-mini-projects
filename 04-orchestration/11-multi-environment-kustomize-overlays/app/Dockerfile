# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src

# Copy dependency manifests and source files
COPY go.mod ./
COPY main.go ./

# Compile static, stripped binary
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/payment-service main.go

# Minimal runtime stage
FROM alpine:3.20

# Create non-root user and group
RUN addgroup -S -g 10001 appgroup && \
    adduser -S -u 10001 -G appgroup -s /sbin/nologin appuser

# Copy compiled binary
COPY --from=builder /bin/payment-service /usr/local/bin/payment-service

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/payment-service"]
