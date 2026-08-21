# ==============================================================================
# Multi-Stage Dockerfile for Config-Reloading Application
# ==============================================================================
# Stage 1: Build static Go binary
FROM golang:1.24-alpine AS builder

WORKDIR /src

# Create unprivileged system user for runtime stage
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -s /sbin/nologin -H -D appuser

# Copy module definition and source files
COPY go.mod ./
COPY main.go ./

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

# Compile static binary stripped of debugging symbols
RUN go build \
    -ldflags="-s -w" \
    -trimpath \
    -o /bin/server .

# ==============================================================================
# Stage 2: Minimal hardened runtime
FROM alpine:3.21 AS runtime

# Install CA certificates for secure outbound TLS and curl for diagnostic probing
RUN apk --no-cache add ca-certificates curl && \
    rm -rf /var/cache/apk/*

# Copy unprivileged user definition from builder stage
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# Copy compiled binary
COPY --from=builder /bin/server /usr/local/bin/server

# Set ownership and unprivileged user
USER 10001:10001

ENV PORT=8080 \
    ENVIRONMENT=production

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/server"]
