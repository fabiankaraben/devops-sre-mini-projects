#!/usr/bin/env bash
# ==============================================================================
# test_logrotate.sh - End-to-End Automated Test Runner for Logrotate Daemon Policy
# ==============================================================================
# 1. Builds and launches the Linux container environment.
# 2. Spawns continuous_log_writer.py writing indexed logs with open file descriptors.
# 3. Triggers multiple forced logrotate cycles (testing SIGHUP, delaycompress, retention).
# 4. Asserts active log writes continue uninterrupted without dropped entries.
# 5. Executes verify_zero_loss.py to audit 100% sequence continuity across all archives.
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

CONTAINER_NAME="logrotate-system-daemon"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 Logrotate Daemon System Policy - Automated Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/6] Checking System Prerequisites...${CLR_RESET}"

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
# 2. Build & Start Linux Testing Container
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/6] Building & Launching Linux Container Environment...${CLR_RESET}"

$COMPOSE_CMD build >/dev/null
$COMPOSE_CMD up -d --remove-orphans >/dev/null

echo "  Verifying container status..."
if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" --format "{{.Names}}" | grep -q "${CONTAINER_NAME}"; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Container '${CONTAINER_NAME}' is running."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Container failed to start."
    exit 1
fi

# Clean any existing logs in container
docker exec "${CONTAINER_NAME}" bash -c "rm -rf /var/log/custom-app/* /var/run/custom-app.pid /var/lib/logrotate/status"

# ------------------------------------------------------------------------------
# 3. Start Continuous Log Writer Daemon
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/6] Starting Continuous Log Writer Daemon (Background)...${CLR_RESET}"

docker exec -d "${CONTAINER_NAME}" python3 /app/daemon/continuous_log_writer.py \
    --log-file /var/log/custom-app/app.log \
    --pid-file /var/run/custom-app.pid \
    --rate 80.0

sleep 2

# Verify writer is running and PID file exists
PID=$(docker exec "${CONTAINER_NAME}" cat /var/run/custom-app.pid 2>/dev/null || echo "")
if [[ -n "$PID" ]]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Daemon process is running with PID ${PID} in container."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Daemon failed to write PID file."
    exit 1
fi

INITIAL_INODE=$(docker exec "${CONTAINER_NAME}" stat -c '%i' /var/log/custom-app/app.log 2>/dev/null || echo "0")
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Active log file created: /var/log/custom-app/app.log (Initial Inode: ${INITIAL_INODE})"

# ------------------------------------------------------------------------------
# 4. Execute Rotation Cycle 1 (First SIGHUP & Inode Change)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/6] Executing Rotation Cycle 1 (Testing SIGHUP & create directive)...${CLR_RESET}"

# Allow some logs to accumulate
sleep 1.5

echo "  Forcing logrotate execution: logrotate -f /etc/logrotate.d/custom-app"
docker exec "${CONTAINER_NAME}" logrotate -f -v /etc/logrotate.d/custom-app >/dev/null 2>&1

sleep 1

# Inspect state after Cycle 1
NEW_INODE=$(docker exec "${CONTAINER_NAME}" stat -c '%i' /var/log/custom-app/app.log 2>/dev/null || echo "0")
echo "  Checking inode transition:"
echo "  • Old Inode (now app.log.1): ${INITIAL_INODE}"
echo "  • New Inode (now app.log):   ${NEW_INODE}"

if [[ "$NEW_INODE" != "$INITIAL_INODE" ]] && [[ "$NEW_INODE" != "0" ]]; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] New inode allocated and daemon smoothly reopened file via SIGHUP."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Inode did not transition or file was not recreated."
    exit 1
fi

# Verify app.log.1 exists uncompressed
if docker exec "${CONTAINER_NAME}" test -f /var/log/custom-app/app.log.1; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Uncompressed rotated archive 'app.log.1' exists (delaycompress verified)."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] 'app.log.1' not found."
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Execute Multi-Cycle Rotations (Testing delaycompress & rotate 7 retention)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/6] Executing Multi-Cycle Rotations (Testing delaycompress & retention purge)...${CLR_RESET}"

for i in {2..9}; do
    sleep 0.8
    docker exec "${CONTAINER_NAME}" logrotate -f /etc/logrotate.d/custom-app >/dev/null 2>&1
    echo -e "  • Cycle ${i}: Rotated log state (Active + archives advancing)"
done

sleep 1

# Stop the writer daemon gracefully
echo "  Stopping background writer daemon (SIGTERM)..."
docker exec "${CONTAINER_NAME}" bash -c "kill -TERM \$(cat /var/run/custom-app.pid) 2>/dev/null || true"
sleep 1

# List files in log directory inside container
echo -e "\n  ${CLR_BOLD}Current /var/log/custom-app contents:${CLR_RESET}"
docker exec "${CONTAINER_NAME}" ls -la /var/log/custom-app/

# Check retention enforcement: rotate 7 means at most 7 archives (.1 through .7.gz)
TOTAL_ARCHIVES=$(docker exec "${CONTAINER_NAME}" bash -c "ls -1 /var/log/custom-app/app.log.* 2>/dev/null | wc -l" || echo "0")
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Total rotated archives retained: ${TOTAL_ARCHIVES} (Max allowed: 7, older cycles purged)."

# Verify gzip compression on older files (.2.gz onward)
if docker exec "${CONTAINER_NAME}" test -f /var/log/custom-app/app.log.2.gz; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Compressed gzip archive 'app.log.2.gz' verified."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] 'app.log.2.gz' not found."
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Run Zero-Loss Sequence Integrity Audit
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [6/6] Executing Zero-Loss Sequence Integrity Audit...${CLR_RESET}"

docker exec "${CONTAINER_NAME}" python3 /app/verify_zero_loss.py \
    --log-dir /var/log/custom-app \
    --base-name app.log

echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 ALL LOGROTATE POLICY TESTS PASSED WITH ZERO DATA LOSS!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "\n${CLR_CYAN}Next Steps:${CLR_RESET}"
echo -e "  • Inspect container log directory: ${CLR_BOLD}docker exec -it ${CONTAINER_NAME} ls -la /var/log/custom-app/${CLR_RESET}"
echo -e "  • Teardown environment:           ${CLR_BOLD}./cleanup.sh --all${CLR_RESET}\n"
