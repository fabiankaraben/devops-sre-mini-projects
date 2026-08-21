# ==============================================================================
# Multi-Stage Dockerfile for ScheduledBackup Kubernetes Operator
# ==============================================================================
# Stage 1: Build static Go binary
FROM golang:1.24-alpine AS builder

WORKDIR /workspace

# Copy modules
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY api/ api/
COPY controllers/ controllers/
COPY main.go ./

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

# Compile static binary stripped of symbols
RUN go build \
    -ldflags="-s -w" \
    -trimpath \
    -o /bin/manager main.go

# Create unprivileged system user
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -s /sbin/nologin -H -D appuser

# ==============================================================================
# Stage 2: Minimal runtime image
FROM alpine:3.21 AS runtime

RUN apk --no-cache add ca-certificates && \
    rm -rf /var/cache/apk/*

COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group
COPY --from=builder /bin/manager /usr/local/bin/manager

USER 10001:10001

ENTRYPOINT ["/usr/local/bin/manager"]
