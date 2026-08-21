FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install SQLite3, GPG, OpenSSL, AWS CLI, Python 3, jq, and core utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    python3 \
    sqlite3 \
    gnupg \
    openssl \
    curl \
    jq \
    coreutils \
    tar \
    gzip \
    awscli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY mock_db_seeder.py backup_s3.sh verify_restore.sh test_backup_restore.sh ./

RUN chmod +x mock_db_seeder.py backup_s3.sh verify_restore.sh test_backup_restore.sh

CMD ["./backup_s3.sh", "--help"]
