FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install sudo, user management tools, ssh client, jq, and core utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    sudo \
    passwd \
    openssh-client \
    python3 \
    coreutils \
    jq \
    gawk \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY users_manifest.csv provision_users.sh cleanup_users.sh test_provision_users.sh ./

RUN chmod +x provision_users.sh cleanup_users.sh test_provision_users.sh

CMD ["./provision_users.sh", "--manifest", "users_manifest.csv", "--dry-run"]
