# ==============================================================================
# Multi-Stage Dockerfile for Zero-Trust Microservices
# ==============================================================================
# Stage 1: Build static Go binaries
FROM golang:1.24-alpine AS builder

WORKDIR /src

# Copy go module files
COPY services/go.mod ./
COPY services/ ./

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

# Compile all microservices stripped of symbols
RUN go build -ldflags="-s -w" -trimpath -o /bin/frontend ./frontend && \
    go build -ldflags="-s -w" -trimpath -o /bin/backend ./backend && \
    go build -ldflags="-s -w" -trimpath -o /bin/database ./database

# Create unprivileged system user
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -s /sbin/nologin -H -D appuser

# ==============================================================================
# Stage 2: Hardened runtime image with network probing utilities
FROM alpine:3.21 AS runtime

RUN apk --no-cache add ca-certificates curl netcat-openbsd bind-tools iputils bash && \
    rm -rf /var/cache/apk/*

COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group
COPY --from=builder /bin/frontend /usr/local/bin/frontend
COPY --from=builder /bin/backend /usr/local/bin/backend
COPY --from=builder /bin/database /usr/local/bin/database

USER 10001:10001

EXPOSE 8080 5432

CMD ["/usr/local/bin/frontend"]
