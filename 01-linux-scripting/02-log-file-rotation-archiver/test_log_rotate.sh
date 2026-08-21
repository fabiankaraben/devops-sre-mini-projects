#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_log_rotate.sh
# Description: Automated Test Suite for Log File Rotation & Archiver.
#              Tests argument handling, size/age rotation, compression,
#              retention policies, and live active producer integration.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROTATE_SCRIPT="${SCRIPT_DIR}/log_rotate.sh"
PRODUCER_SCRIPT="${SCRIPT_DIR}/mock_log_producer.py"
TEST_SANDBOX="/tmp/log_rotate_test_sandbox_$$"

# Color helpers
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

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

validate_json() {
    local json_str="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$json_str" | jq . >/dev/null 2>&1
        return $?
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys, json; json.loads(sys.stdin.read())" <<< "$json_str" >/dev/null 2>&1
        return $?
    else
        return 0
    fi
}

cleanup() {
    # Terminate any background producer spawned during test
    if [[ -n "${PRODUCER_PID:-}" ]]; then
        if kill -0 "$PRODUCER_PID" 2>/dev/null; then
            kill -INT "$PRODUCER_PID" 2>/dev/null || true
            wait "$PRODUCER_PID" 2>/dev/null || true
        fi
    fi
    # Clean test sandbox
    rm -rf "$TEST_SANDBOX" 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}  Log File Rotation and Archiver - Automated Tests   ${NC}"
echo -e "${BLUE}======================================================${NC}\n"

# Setup clean test sandbox
rm -rf "$TEST_SANDBOX"
mkdir -p "${TEST_SANDBOX}/logs" "${TEST_SANDBOX}/archive"

# ------------------------------------------------------------------------------
# Suite 1: CLI Arguments & Help
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Arguments & Help Handling${NC}"

set +e
output=$("$ROTATE_SCRIPT" --help 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 0 && "$output" =~ "Usage:" ]]; then
    report_test "--help displays usage and exits 0" "PASS"
else
    report_test "--help displays usage and exits 0" "FAIL" "Exit code: ${exit_code}"
fi

set +e
output=$("$ROTATE_SCRIPT" --invalid-opt 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 2 ]]; then
    report_test "Unknown flag triggers exit code 2 (ERROR)" "PASS"
else
    report_test "Unknown flag triggers exit code 2 (ERROR)" "FAIL" "Expected 2, got: ${exit_code}"
fi

set +e
output=$("$ROTATE_SCRIPT" --log-dir "/non_existent_dir_$$" 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 2 ]]; then
    report_test "Non-existent log directory triggers exit code 2" "PASS"
else
    report_test "Non-existent log directory triggers exit code 2" "FAIL" "Expected 2, got: ${exit_code}"
fi

# ------------------------------------------------------------------------------
# Suite 2: Dry Run Mode
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Dry Run Mode Simulation${NC}"

echo "Line 1" > "${TEST_SANDBOX}/logs/test1.log"
echo "Line 2" > "${TEST_SANDBOX}/logs/test2.log"

set +e
dry_output=$("$ROTATE_SCRIPT" --log-dir "${TEST_SANDBOX}/logs" --archive-dir "${TEST_SANDBOX}/archive" --dry-run --json 2>&1)
dry_exit=$?
set -e

if [[ $dry_exit -eq 0 ]]; then
    report_test "Dry-run completes successfully with exit code 0" "PASS"
else
    report_test "Dry-run completes successfully with exit code 0" "FAIL" "Got exit code: ${dry_exit}"
fi

# Assert original files still contain their data and no archive was written
arch_count=$(find "${TEST_SANDBOX}/archive" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$arch_count" -eq 0 && -s "${TEST_SANDBOX}/logs/test1.log" ]]; then
    report_test "Dry-run did not alter active files or write archives" "PASS"
else
    report_test "Dry-run did not alter active files or write archives" "FAIL" "Archives found: ${arch_count}"
fi

# ------------------------------------------------------------------------------
# Suite 3: Size-based Log Rotation & Gzip Compression
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Size-Based Rotation & Compression${NC}"

# Create 150KB file (should rotate) and 10KB file (should NOT rotate with --max-size 100K)
dd if=/dev/zero of="${TEST_SANDBOX}/logs/large.log" bs=1024 count=150 status=none
dd if=/dev/zero of="${TEST_SANDBOX}/logs/small.log" bs=1024 count=10 status=none

set +e
rot_output=$("$ROTATE_SCRIPT" --log-dir "${TEST_SANDBOX}/logs" --archive-dir "${TEST_SANDBOX}/archive" --max-size 100K --json 2>&1)
rot_exit=$?
set -e

if [[ $rot_exit -eq 0 ]]; then
    report_test "Size-based rotation executes with exit code 0" "PASS"
else
    report_test "Size-based rotation executes with exit code 0" "FAIL" "Exit code: ${rot_exit}"
fi

# Check that large.log was truncated to 0 bytes and small.log remains non-empty
large_size=$(wc -c < "${TEST_SANDBOX}/logs/large.log" | tr -d ' ')
small_size=$(wc -c < "${TEST_SANDBOX}/logs/small.log" | tr -d ' ')

if [[ "$large_size" -eq 0 && "$small_size" -gt 0 ]]; then
    report_test "large.log truncated in-place while small.log preserved" "PASS"
else
    report_test "large.log truncated in-place while small.log preserved" "FAIL" "large: ${large_size}, small: ${small_size}"
fi

# Verify archive integrity with gzip -t
arch_file=$(find "${TEST_SANDBOX}/archive" -name "large_*.log.gz" | head -n 1)
if [[ -n "$arch_file" && -f "$arch_file" ]]; then
    if gzip -t "$arch_file" 2>/dev/null; then
        report_test "Rotated gzip archive is valid and uncorrupted" "PASS"
    else
        report_test "Rotated gzip archive is valid and uncorrupted" "FAIL" "gzip test failed"
    fi
else
    report_test "Rotated gzip archive is valid and uncorrupted" "FAIL" "Archive file not found"
fi

# ------------------------------------------------------------------------------
# Suite 4: Retention Policy & Pruning
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Retention Policy & Archive Pruning${NC}"

# Clean archive directory and generate 5 mock archives with spaced modification times
rm -rf "${TEST_SANDBOX}/archive"/*
for i in {1..5}; do
    arch_dummy="${TEST_SANDBOX}/archive/app_2026-08-0${i}T00-00-00Z.log.gz"
    echo "test log content $i" | gzip -c > "$arch_dummy"
    # Touch with spaced dates (e.g. 1st, 2nd, 3rd, 4th, 5th)
    touch -t "2026080${i}0000" "$arch_dummy" 2>/dev/null || touch "$arch_dummy"
    sleep 0.1
done

# Run rotation with --retention-count 2
set +e
ret_output=$("$ROTATE_SCRIPT" --log-dir "${TEST_SANDBOX}/logs" --archive-dir "${TEST_SANDBOX}/archive" --retention-count 2 --json 2>&1)
ret_exit=$?
set -e

remaining_archives=$(find "${TEST_SANDBOX}/archive" -name "*.gz" | wc -l | tr -d ' ')
if [[ $ret_exit -eq 0 && "$remaining_archives" -eq 2 ]]; then
    report_test "--retention-count 2 pruned older archives down to 2" "PASS"
else
    report_test "--retention-count 2 pruned older archives down to 2" "FAIL" "Remaining archives: ${remaining_archives}"
fi

# ------------------------------------------------------------------------------
# Suite 5: Active Background Daemon Integration
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Active Background Daemon Non-Destructive Rotation${NC}"

ACTIVE_LOG="${TEST_SANDBOX}/logs/live_app.log"
rm -f "$ACTIVE_LOG"

# Start mock log producer in background producing 25 logs/second
python3 "$PRODUCER_SCRIPT" --log-file "$ACTIVE_LOG" --rate 25 --format json >/dev/null 2>&1 &
PRODUCER_PID=$!

# Allow daemon to start and write initial entries
sleep 0.8

initial_entries=$(wc -l < "$ACTIVE_LOG" | tr -d ' ')
if [[ "$initial_entries" -gt 0 ]]; then
    report_test "mock_log_producer actively writing entries ($initial_entries lines)" "PASS"
else
    report_test "mock_log_producer actively writing entries" "FAIL" "Log file empty"
fi

# Execute rotation while producer is running
set +e
live_rotate_output=$("$ROTATE_SCRIPT" --log-dir "${TEST_SANDBOX}/logs" --archive-dir "${TEST_SANDBOX}/archive" --pattern "live_app.log" --json 2>&1)
live_rotate_exit=$?
set -e

# Let producer write for another second after rotation
sleep 0.8

# Stop producer
kill -INT "$PRODUCER_PID" 2>/dev/null || true
wait "$PRODUCER_PID" 2>/dev/null || true
PRODUCER_PID=""

# Verify that live_app.log received new entries after rotation occurred
post_entries=$(wc -l < "$ACTIVE_LOG" | tr -d ' ')
arch_live=$(find "${TEST_SANDBOX}/archive" -name "live_app_*.log.gz" | head -n 1)

if [[ $live_rotate_exit -eq 0 && -n "$arch_live" && "$post_entries" -gt 0 ]]; then
    report_test "Active log rotation succeeded with uninterrupted logging ($post_entries post-rotation lines)" "PASS"
else
    report_test "Active log rotation succeeded with uninterrupted logging" "FAIL" "Post lines: ${post_entries}, Exit: ${live_rotate_exit}"
fi

if validate_json "$live_rotate_output"; then
    report_test "Rotation summary outputs valid JSON schema" "PASS"
else
    report_test "Rotation summary outputs valid JSON schema" "FAIL" "Invalid JSON generated"
fi

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
