FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install Python 3, curl, jq, procps, and core utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    python3 \
    curl \
    jq \
    procps \
    coreutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY flaky_service.py watchdog.py watchdog.sh test_watchdog.sh ./

RUN chmod +x flaky_service.py watchdog.py watchdog.sh test_watchdog.sh

EXPOSE 8080

CMD ["./watchdog.sh", "--help"]
