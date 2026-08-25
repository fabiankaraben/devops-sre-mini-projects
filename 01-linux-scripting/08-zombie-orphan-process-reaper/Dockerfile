FROM debian:bookworm-slim

# Install GCC, Python3, procps, dumb-init, and build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc6-dev \
    python3 \
    python3-minimal \
    procps \
    psmisc \
    bash \
    dumb-init \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy scripts and simulator
COPY zombie_spawner.c zombie_spawner.py process_reaper.py process_reaper.sh ./
RUN chmod +x zombie_spawner.py process_reaper.py process_reaper.sh

# Compile C simulator
RUN gcc -Wall -Wextra -O2 zombie_spawner.c -o /usr/local/bin/zombie_spawner

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["python3", "process_reaper.py", "--scan"]
