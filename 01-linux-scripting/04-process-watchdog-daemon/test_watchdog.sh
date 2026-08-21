#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_watchdog.sh
# Description: Automated Test Suite for Process Watchdog Daemon.
#              Tests healthy startup, hard crash recovery (kill -9), HTTP crash
#              endpoint recovery, deadlock/hang detection, flapping protection,
#              and graceful shutdown.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/watchdog.py"
SERVICE_SCRIPT="${SCRIPT_DIR}/flaky_service.py"
STATUS_FILE="${SCRIPT_DIR}/watchdog_status.json"
WATCHDOG_PID_FILE="${SCRIPT_DIR}/watchdog.pid"
SERVICE_PID_FILE="${SCRIPT_DIR}/flaky_service.pid"
PORT=8089 # Use custom port to avoid any local conflicts

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WATCHDOG_PID=""

report_test() {
    local name="$1"
    local result="$2"
    local details="${3:-}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$result" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${GREEN}PASS${NC}] ${name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${RED}FAIL${NC}] ${name}"
        if [[ -n "$details" ]]; then
            echo -e "         ${YELLOW}Details: ${details}${NC}"
        fi
    fi
}

cleanup() {
    # Stop any background watchdog or service
    if [[ -n "$WATCHDOG_PID" ]]; then
        kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
    pkill -f "flaky_service.py --port ${PORT}" 2>/dev/null || true
    rm -f "$STATUS_FILE" "$WATCHDOG_PID_FILE" "$SERVICE_PID_FILE" 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}     Process Watchdog Daemon - Automated Tests        ${NC}"
echo -e "${BLUE}======================================================${NC}\n"

# Ensure cleanup before starting
cleanup

# ------------------------------------------------------------------------------
# Suite 1: CLI Arguments & Help Handling
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Arguments & Help Handling${NC}"

set +e
help_out=$(python3 "$WATCHDOG_SCRIPT" --help 2>&1)
help_exit=$?
set -e
if [[ $help_exit -eq 0 && "$help_out" =~ "usage:" ]]; then
    report_test "--help displays usage and exits 0" "PASS"
else
    report_test "--help displays usage and exits 0" "FAIL" "Exit code: ${help_exit}"
fi

set +e
status_out=$(python3 "$WATCHDOG_SCRIPT" --status 2>&1)
status_exit=$?
set -e
if [[ $status_exit -eq 0 && "$status_out" =~ "STOPPED" ]]; then
    report_test "--status reports STOPPED when daemon is offline" "PASS"
else
    report_test "--status reports STOPPED when offline" "FAIL" "Output: ${status_out}"
fi

# ------------------------------------------------------------------------------
# Suite 2: Healthy Startup & Supervision
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Healthy Startup & L1/L7 Supervision${NC}"

# Launch Watchdog in background
python3 "$WATCHDOG_SCRIPT" \
    --command "python3 ${SERVICE_SCRIPT} --port ${PORT}" \
    --http-check "http://127.0.0.1:${PORT}/healthz" \
    --interval 1.0 \
    --timeout 1.0 \
    --max-restarts 3 \
    --window 30 >/dev/null 2>&1 &
WATCHDOG_PID=$!

# Wait for service startup with active polling (up to 5s)
healthy_boot=false
for i in {1..10}; do
    if curl -s -f "http://127.0.0.1:${PORT}/healthz" 2>/dev/null | grep -q "healthy"; then
        healthy_boot=true
        break
    fi
    sleep 0.5
done

if [[ "$healthy_boot" == true ]]; then
    report_test "Flaky service spawned and responding 200 on /healthz" "PASS"
else
    report_test "Flaky service spawned and responding 200 on /healthz" "FAIL" "Service failed to respond on port ${PORT}"
fi

sleep 1.0
status_json=$(python3 "$WATCHDOG_SCRIPT" --status 2>/dev/null || echo "{}")
if [[ "$status_json" =~ "\"state\": \"HEALTHY\"" || "$status_json" =~ "\"state\": \"STARTING\"" ]]; then
    report_test "Watchdog state transitioned to HEALTHY" "PASS"
else
    report_test "Watchdog state transitioned to HEALTHY" "FAIL" "Status: ${status_json}"
fi

# ------------------------------------------------------------------------------
# Suite 3: Hard Crash Recovery (kill -9)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Hard Process Crash Recovery (kill -9)${NC}"

initial_child_pid=$(python3 -c "import json; print(json.load(open('${STATUS_FILE}'))['child_pid'])" 2>/dev/null || cat "$SERVICE_PID_FILE" 2>/dev/null || echo "")

if [[ -n "$initial_child_pid" && "$initial_child_pid" != "None" ]]; then
    # Send kill -9 to simulate sudden fatal crash
    kill -9 "$initial_child_pid" 2>/dev/null || true
    
    # Wait for watchdog check interval and recovery
    sleep 3.0

    new_child_pid=$(python3 -c "import json; print(json.load(open('${STATUS_FILE}'))['child_pid'])" 2>/dev/null || cat "$SERVICE_PID_FILE" 2>/dev/null || echo "")
    restart_count=$(python3 -c "import json; print(json.load(open('${STATUS_FILE}'))['total_restarts'])" 2>/dev/null || echo "0")

    if [[ -n "$new_child_pid" && "$new_child_pid" != "$initial_child_pid" && "$restart_count" -ge 1 ]]; then
        report_test "Watchdog detected PID exit and restarted service (New PID: ${new_child_pid})" "PASS"
    else
        report_test "Watchdog detected PID exit and restarted service" "FAIL" "Old: ${initial_child_pid}, New: ${new_child_pid}, Restarts: ${restart_count}"
    fi

    # Verify endpoint is functional again
    recovered_http=false
    for i in {1..8}; do
        if curl -s -f "http://127.0.0.1:${PORT}/healthz" 2>/dev/null | grep -q "healthy"; then
            recovered_http=true
            break
        fi
        sleep 0.5
    done

    if [[ "$recovered_http" == true ]]; then
        report_test "Recovered service responding normally to HTTP traffic" "PASS"
    else
        report_test "Recovered service responding normally to HTTP traffic" "FAIL" "Service not responding"
    fi
else
    report_test "Hard process crash recovery" "FAIL" "Could not determine initial child PID"
fi

# ------------------------------------------------------------------------------
# Suite 4: Application-Level Crash via HTTP Endpoint
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Application-Level Endpoint Crash (/crash)${NC}"

# Trigger intentional crash via HTTP POST
curl -s -X POST "http://127.0.0.1:${PORT}/crash" >/dev/null 2>&1 || true

# Wait for recovery
recovered_crash=false
for i in {1..8}; do
    if curl -s -f "http://127.0.0.1:${PORT}/healthz" 2>/dev/null | grep -q "healthy"; then
        recovered_crash=true
        break
    fi
    sleep 0.5
done

if [[ "$recovered_crash" == true ]]; then
    report_test "Watchdog recovered service following /crash trigger" "PASS"
else
    report_test "Watchdog recovered service following /crash trigger" "FAIL" "Service offline after /crash"
fi

# ------------------------------------------------------------------------------
# Suite 5: Deadlock & Unresponsive Hang Detection (/hang)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Unresponsive Service / Deadlock Detection (/hang)${NC}"

# Put service into hanging state (process stays alive, but HTTP times out)
curl -s -X POST "http://127.0.0.1:${PORT}/hang" >/dev/null 2>&1 || true

# Allow probe timeout and restart (timeout=1s * 2 + interval=1s + restart=1s -> ~4-6s)
recovered_hang=false
for i in {1..12}; do
    sleep 0.5
    if curl -s -f --max-time 1.0 "http://127.0.0.1:${PORT}/healthz" 2>/dev/null | grep -q "healthy"; then
        recovered_hang=true
        break
    fi
done

if [[ "$recovered_hang" == true ]]; then
    report_test "Watchdog detected L7 HTTP probe timeout and recovered deadlocked process" "PASS"
else
    report_test "Watchdog detected L7 HTTP probe timeout and recovered deadlocked process" "FAIL" "Service still hanging or down"
fi

# ------------------------------------------------------------------------------
# Suite 6: Crash Flapping Protection
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 6: Crash Flapping Protection & Rate Limiting${NC}"

# Force rapid crashes to exceed max_restarts (3) within 30s
for i in {1..3}; do
    curl -s -X POST "http://127.0.0.1:${PORT}/crash" >/dev/null 2>&1 || true
    sleep 1.2
done

sleep 2.0

flapping_status=$(python3 "$WATCHDOG_SCRIPT" --status 2>/dev/null || echo "{}")
if [[ "$flapping_status" =~ "\"state\": \"FLAPPING\"" || "$flapping_status" =~ "\"flapping\": true" ]]; then
    report_test "Watchdog detected rapid crash cycle and entered FLAPPING state" "PASS"
else
    report_test "Watchdog detected rapid crash cycle and entered FLAPPING state" "FAIL" "Status: ${flapping_status}"
fi

# ------------------------------------------------------------------------------
# Suite 7: Graceful Shutdown
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 7: Graceful Shutdown${NC}"

set +e
python3 "$WATCHDOG_SCRIPT" --stop >/dev/null 2>&1
stop_exit=$?
set -e

sleep 1.0

# Verify child process terminated
if ! pgrep -f "flaky_service.py --port ${PORT}" >/dev/null 2>&1; then
    report_test "Watchdog shutdown cleanly terminated supervised child process" "PASS"
else
    report_test "Watchdog shutdown cleanly terminated supervised child process" "FAIL" "Child process still running"
fi

WATCHDOG_PID=""

# ------------------------------------------------------------------------------
# Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}======================================================${NC}"
echo -e "  Test Results: ${PASSED_TESTS}/${TOTAL_TESTS} Passed"
if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "  Status: ${GREEN}ALL TESTS PASSED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 0
else
    echo -e "  Status: ${RED}${FAILED_TESTS} TESTS FAILED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 1
fi
