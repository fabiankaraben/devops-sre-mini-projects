FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install bash, Python 3, gzip, lsof, jq, and core utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    python3 \
    coreutils \
    gzip \
    lsof \
    jq \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY log_rotate.sh mock_log_producer.py test_log_rotate.sh ./

RUN chmod +x log_rotate.sh mock_log_producer.py test_log_rotate.sh

ENTRYPOINT ["./log_rotate.sh"]
CMD ["--help"]
