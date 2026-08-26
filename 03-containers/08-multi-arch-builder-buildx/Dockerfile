# ==============================================================================
# Dockerfile - Multi-Architecture High-Performance Build with BuildKit
# ==============================================================================
# Demonstrates native cross-compilation leveraging BuildKit platform arguments
# (BUILDPLATFORM, TARGETOS, TARGETARCH) for maximum build speed without QEMU lag.
# ==============================================================================

# --- Stage 1: Fast Native Cross-Compilation ---
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

# Automatically provided by Docker Buildx
ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH

RUN echo "Compiling on native host platform: $BUILDPLATFORM for target: $TARGETPLATFORM ($TARGETOS/$TARGETARCH)"

WORKDIR /src
COPY app/go.mod ./
COPY app/main.go ./

# Compile statically for the target architecture
RUN CGO_ENABLED=0 \
    GOOS=${TARGETOS:-linux} \
    GOARCH=${TARGETARCH:-amd64} \
    go build -ldflags="-s -w" -o /app/server .

# --- Stage 2: Minimal Hardened Runtime Container ---
FROM alpine:3.20

# Create unprivileged application user
RUN addgroup -g 10001 appgroup && \
    adduser -u 10001 -G appgroup -D -s /sbin/nologin appuser

WORKDIR /app
COPY --from=builder /app/server /app/server

RUN chmod +x /app/server && \
    chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

ENTRYPOINT ["/app/server"]
