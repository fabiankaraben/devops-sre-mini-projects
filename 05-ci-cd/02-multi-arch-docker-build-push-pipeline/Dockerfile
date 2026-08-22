# ==============================================================================
# Multi-Architecture Multi-Stage Dockerfile
# Optimized with native Go cross-compilation via BuildKit TARGETPLATFORM
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Builder (Runs natively on BuildKit host architecture)
# ------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

# BuildKit automatically populates these arguments
ARG TARGETOS
ARG TARGETARCH
ARG TARGETPLATFORM

WORKDIR /src

# Install certificates and create non-root user
RUN apk add --no-cache ca-certificates && \
    adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid 10001 \
    appuser

# Copy dependency definitions and source code
COPY app/go.mod ./
COPY app/*.go ./

# Compile statically-linked binary for the target architecture
RUN CGO_ENABLED=0 \
    GOOS=${TARGETOS:-linux} \
    GOARCH=${TARGETARCH:-amd64} \
    go build \
    -ldflags="-s -w -extldflags '-static'" \
    -trimpath \
    -o /bin/server .

# ------------------------------------------------------------------------------
# Stage 2: Minimal Hardened Runtime
# ------------------------------------------------------------------------------
FROM alpine:3.21 AS runtime

# Install CA certificates for outbound HTTPS calls
RUN apk add --no-cache ca-certificates tzdata

# Import non-root user from builder
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# Import compiled static binary
COPY --from=builder /bin/server /bin/server

# Run as non-privileged user (appuser: UID 10001)
USER 10001:10001

EXPOSE 8080

# Built-in lightweight health check using Alpine BusyBox wget
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz > /dev/null || exit 1

ENTRYPOINT ["/bin/server"]
