# ==============================================================================
# Dockerfile - Custom Container Runtime from Scratch Laboratory
# ==============================================================================
FROM golang:alpine

# Install build dependencies, diagnostics, and container toolchains
RUN apk add --no-cache \
    bash \
    curl \
    util-linux \
    procps \
    coreutils \
    ca-certificates

WORKDIR /src

# Copy source code and compile custom container runtime
COPY go.mod ./
COPY my_runtime.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /usr/local/bin/my_runtime .

# Copy scripts and prepare rootfs
WORKDIR /lab
COPY setup_rootfs.sh /lab/setup_rootfs.sh
COPY runtime_test_suite.sh /lab/runtime_test_suite.sh
COPY test_runtime.sh /lab/test_runtime.sh

RUN chmod +x /lab/*.sh && \
    /lab/setup_rootfs.sh /rootfs

# Create host-level secret marker to prove filesystem isolation
RUN echo "HOST_ENVIRONMENT_SECRET_TOKEN_DO_NOT_LEAK" > /HOST_SYSTEM_FLAG.txt

WORKDIR /lab

ENTRYPOINT ["/bin/bash"]
CMD ["/lab/runtime_test_suite.sh"]
