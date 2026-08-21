# ==============================================================================
# Multi-Stage Dockerfile for Argo Rollouts Sample Application
# ==============================================================================
# Stage 1: Build static Go binary
FROM golang:1.24-alpine AS builder

WORKDIR /src

ARG VERSION=v1.0.0
ARG DEFAULT_ERROR_RATE=0.0

# Create unprivileged system user
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -s /sbin/nologin -H -D appuser

# Copy source code and modules
COPY go.mod ./
COPY main.go ./

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

# Compile static binary stripped of symbols
RUN go build \
    -ldflags="-s -w -X main.appVersion=${VERSION}" \
    -trimpath \
    -o /bin/rollout-app .

# ==============================================================================
# Stage 2: Minimal runtime image
FROM alpine:3.21 AS runtime

ARG VERSION=v1.0.0
ARG DEFAULT_ERROR_RATE=0.0

RUN apk --no-cache add ca-certificates curl && \
    rm -rf /var/cache/apk/*

COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group
COPY --from=builder /bin/rollout-app /usr/local/bin/rollout-app

USER 10001:10001

ENV PORT=8080 \
    APP_VERSION=${VERSION} \
    ERROR_RATE=${DEFAULT_ERROR_RATE}

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/rollout-app"]
