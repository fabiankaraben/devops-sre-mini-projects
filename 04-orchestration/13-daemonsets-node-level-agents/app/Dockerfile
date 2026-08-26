# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/node-system-agent main.go

# Minimal runtime stage
FROM alpine:3.20

RUN addgroup -S -g 10001 agentgroup && \
    adduser -S -u 10001 -G agentgroup -s /sbin/nologin agentuser

COPY --from=builder /bin/node-system-agent /usr/local/bin/node-system-agent

USER 10001:10001
EXPOSE 9100

ENTRYPOINT ["/usr/local/bin/node-system-agent"]
