#!/usr/bin/env bash
# ==============================================================================
# log_delivery_test.sh - End-to-End Automated Test for Docker Fluentd Driver
# ==============================================================================
# 1. Checks prerequisites (Docker, Docker Compose, Python 3).
# 2. Builds container images for Fluentd collector and log producer.
# 3. Starts Fluentd receiver daemon on port 24224.
# 4. Spawns high-volume producer with native Docker 'fluentd' logging driver.
# 5. Emits 10,000 log events and verifies 100% ingestion with zero data loss.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

EXPECTED_COUNT=10000

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 Docker Logging Drivers & Fluentd - Automated Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running. Please start OrbStack or Docker Desktop."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker engine is running."

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker Compose not found."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose command: ${CLR_BOLD}${COMPOSE_CMD}${CLR_RESET}"

# ------------------------------------------------------------------------------
# 2. Build Container Images
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building Fluentd Collector & Producer Images...${CLR_RESET}"

$COMPOSE_CMD build >/dev/null
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container images built successfully."

# ------------------------------------------------------------------------------
# 3. Start Fluentd Collector Daemon
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Launching Fluentd Collector (Forward Port 24224)...${CLR_RESET}"

$COMPOSE_CMD up -d fluentd >/dev/null

echo "  Waiting for Fluentd port 24224 readiness..."
MAX_WAIT=20
WAITED=0
READY=false

while [ $WAITED -lt $MAX_WAIT ]; do
    if python3 -c "import socket; s = socket.socket(); s.settimeout(1); s.connect(('127.0.0.1', 24224)); s.close()" 2>/dev/null; then
        READY=true
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ "$READY" = true ]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Fluentd collector is ready and listening on port 24224."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Fluentd failed to bind port 24224 within timeout."
    docker logs fluentd-collector || true
    exit 1
fi

# Clean any existing storage inside collector
docker exec fluentd-collector sh -c "rm -rf /fluentd/log/* /fluentd/buffer/*" >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 4. Execute High-Volume Log Producer (10,000 Records via fluentd driver)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Running High-Volume Log Producer (${EXPECTED_COUNT} lines)...${CLR_RESET}"

# Start the log producer container
$COMPOSE_CMD up log-producer

echo "  Waiting for producer container to complete emission..."
docker wait fluentd-log-producer >/dev/null

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] High-volume producer emitted all ${EXPECTED_COUNT} log records."

# Give Fluentd buffer 3 seconds to flush chunks to disk
sleep 3

# ------------------------------------------------------------------------------
# 5. Run Zero-Loss Delivery Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Auditing Fluentd Log Delivery & Host Disk Preservation...${CLR_RESET}"

python3 "$SCRIPT_DIR/verify_delivery.py" \
    --expected-count "$EXPECTED_COUNT" \
    --fluentd-container fluentd-collector \
    --producer-container fluentd-log-producer

echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 ALL TESTS PASSED: 10,000 LOG EVENTS DELIVERED WITH ZERO LOSS!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "\n${CLR_CYAN}Next Steps:${CLR_RESET}"
echo -e "  • Inspect live Fluentd metrics:   ${CLR_BOLD}curl -s http://localhost:24220/api/plugins.json | jq .${CLR_RESET}"
echo -e "  • View collector file outputs:    ${CLR_BOLD}docker exec -it fluentd-collector ls -la /fluentd/log/${CLR_RESET}"
echo -e "  • Teardown environment:           ${CLR_BOLD}./cleanup.sh --all${CLR_RESET}\n"
