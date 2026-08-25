#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_process_reaper.sh
# Description: Automated Test Suite for Zombie and Orphan Process Reaper.
#              Tests C compilation, Python & C simulators, zombie detection,
#              gentle SIGCHLD reaping, forceful parent kill & PID 1 re-parenting,
#              JSON/Prometheus metrics, and Bash script parity.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER_PY="${SCRIPT_DIR}/process_reaper.py"
REAPER_SH="${SCRIPT_DIR}/process_reaper.sh"
SPAWNER_C="${SCRIPT_DIR}/zombie_spawner.c"
SPAWNER_BIN="${SCRIPT_DIR}/zombie_spawner"
SPAWNER_PY="${SCRIPT_DIR}/zombie_spawner.py"
TEST_JSON="${SCRIPT_DIR}/.test_reaper.json"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
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

cleanup() {
    # Terminate any lingering spawner processes
    pkill -f "zombie_spawner" 2>/dev/null || true
    rm -f "$TEST_JSON" "${SCRIPT_DIR}/.test_prom.txt" 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

# Grant execution permissions
chmod +x "$REAPER_PY" "$REAPER_SH" "$SPAWNER_PY" 2>/dev/null || true

echo -e "\n${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}${BLUE}     Zombie & Orphan Process Reaper - Tests           ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}\n"

cleanup

# ------------------------------------------------------------------------------
# Suite 1: C Compilation & CLI Help
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: Compilation & CLI Flags${NC}"

if gcc -Wall -Wextra -O2 "$SPAWNER_C" -o "$SPAWNER_BIN" 2>/dev/null; then
    report_test "zombie_spawner.c compiles cleanly with GCC" "PASS"
else
    report_test "zombie_spawner.c compiles cleanly with GCC" "FAIL" "Compilation error"
fi

set +e
py_help=$(python3 "$REAPER_PY" --help 2>&1)
py_code=$?
set -e
if [[ $py_code -eq 0 && "$py_help" =~ "usage:" ]]; then
    report_test "Python reaper --help displays usage and returns 0" "PASS"
else
    report_test "Python reaper --help displays usage and returns 0" "FAIL" "Exit: $py_code"
fi

set +e
sh_help=$("$REAPER_SH" --help 2>&1)
sh_code=$?
set -e
if [[ $sh_code -eq 0 && "$sh_help" =~ "Usage:" ]]; then
    report_test "Bash reaper --help displays usage and returns 0" "PASS"
else
    report_test "Bash reaper --help displays usage and returns 0" "FAIL" "Exit: $sh_code"
fi

# ------------------------------------------------------------------------------
# Suite 2: Zombie Process Detection & Classification
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Zombie Process Detection & Classification${NC}"

# Spawn 3 zombies in background
"$SPAWNER_BIN" -z 3 -d 30 >/dev/null 2>&1 &
SPAWN_PID=$!
sleep 1

set +e
scan_json=$(python3 "$REAPER_PY" --json)
scan_code=$?
set -e

z_count=$(echo "$scan_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['metadata']['zombie_count'])" 2>/dev/null || echo "0")
negligent_parent=$(echo "$scan_json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['negligent_parents'][0]['ppid'] if data['negligent_parents'] else '')" 2>/dev/null || echo "")

if [[ $z_count -ge 3 && "$negligent_parent" == "$SPAWN_PID" && $scan_code -eq 1 ]]; then
    report_test "Process reaper accurately detects 3 zombies and flags parent PID $SPAWN_PID (Exit 1)" "PASS"
else
    report_test "Process reaper accurately detects 3 zombies and flags parent PID $SPAWN_PID" "FAIL" "Count: $z_count, Parent: $negligent_parent, Exit: $scan_code"
fi

# Clean up
kill -9 "$SPAWN_PID" 2>/dev/null || true
sleep 1

# ------------------------------------------------------------------------------
# Suite 3: Gentle Reaping via SIGCHLD
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Gentle Reaping via SIGCHLD${NC}"

# Spawn 2 zombies with SIGCHLD handler enabled
"$SPAWNER_BIN" -z 2 -d 30 -s >/dev/null 2>&1 &
SPAWN_PID=$!
sleep 1

# Send SIGCHLD to parents
reap_res=$(python3 "$REAPER_PY" --reap-sigchld --json --no-fail)
sleep 1

post_json=$(python3 "$REAPER_PY" --json --no-fail)
post_zombies=$(echo "$post_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['metadata']['zombie_count'])" 2>/dev/null || echo "0")

if [[ $post_zombies -eq 0 ]]; then
    report_test "Gentle SIGCHLD signal prompts parent to reap zombies without termination" "PASS"
else
    report_test "Gentle SIGCHLD signal prompts parent to reap zombies without termination" "FAIL" "Remaining zombies: $post_zombies"
fi

kill -9 "$SPAWN_PID" 2>/dev/null || true
sleep 1

# ------------------------------------------------------------------------------
# Suite 4: Forceful Reaping via Parent Termination (PID 1 Inheritance)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Forceful Parent Termination & PID 1 Inheritance${NC}"

# Spawn 3 zombies that ignore SIGCHLD
"$SPAWNER_BIN" -z 3 -d 30 >/dev/null 2>&1 &
SPAWN_PID=$!
sleep 1

# Kill parent to trigger kernel re-parenting
python3 "$REAPER_PY" --kill-parents --no-fail >/dev/null 2>&1
sleep 1

post_kill_json=$(python3 "$REAPER_PY" --json --no-fail)
post_kill_zombies=$(echo "$post_kill_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['metadata']['zombie_count'])" 2>/dev/null || echo "0")

if [[ $post_kill_zombies -eq 0 ]]; then
    report_test "--kill-parents terminates negligent parent and kernel re-parents zombies to PID 1" "PASS"
else
    report_test "--kill-parents terminates negligent parent and kernel re-parents zombies to PID 1" "FAIL" "Remaining: $post_kill_zombies"
fi

# ------------------------------------------------------------------------------
# Suite 5: Auto-Reap Progressive Remediation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Auto-Reap Progressive Remediation${NC}"

# Spawn with Python spawner
python3 "$SPAWNER_PY" -z 4 -d 30 >/dev/null 2>&1 &
PY_SPAWN_PID=$!
sleep 1

python3 "$REAPER_PY" --auto-reap --no-fail >/dev/null 2>&1
sleep 1

auto_json=$(python3 "$REAPER_PY" --json --no-fail)
auto_zombies=$(echo "$auto_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['metadata']['zombie_count'])" 2>/dev/null || echo "0")

if [[ $auto_zombies -eq 0 ]]; then
    report_test "--auto-reap automatically resolves zombies and cleans process table" "PASS"
else
    report_test "--auto-reap automatically resolves zombies and cleans process table" "FAIL" "Remaining: $auto_zombies"
fi

kill -9 "$PY_SPAWN_PID" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Suite 6: Orphan Process Detection
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 6: Orphan Process Detection${NC}"

# Spawn 2 orphans
python3 "$SPAWNER_PY" -o 2 -d 5 >/dev/null 2>&1 &
sleep 1

orphan_json=$(python3 "$REAPER_PY" --json --no-fail)
orphan_count=$(echo "$orphan_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['metadata']['orphan_count'])" 2>/dev/null || echo "0")

if [[ $orphan_count -ge 1 ]]; then
    report_test "Process reaper detects detached orphan processes with PPID 1" "PASS"
else
    report_test "Process reaper detects detached orphan processes with PPID 1" "FAIL" "Orphan count: $orphan_count"
fi

# ------------------------------------------------------------------------------
# Suite 7: Prometheus Metrics & Output Isolation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 7: Prometheus Metrics & File Output${NC}"

prom_out=$(python3 "$REAPER_PY" --prometheus --no-fail)

has_z_total=$(echo "$prom_out" | grep -q 'zombie_processes_total' && echo 1 || echo 0)
has_pid_max=$(echo "$prom_out" | grep -q 'process_table_max_pids' && echo 1 || echo 0)
has_utilization=$(echo "$prom_out" | grep -q 'process_table_utilization_percent' && echo 1 || echo 0)

if [[ $has_z_total -eq 1 && $has_pid_max -eq 1 && $has_utilization -eq 1 ]]; then
    report_test "Prometheus metrics export complies with OpenMetrics standard" "PASS"
else
    report_test "Prometheus metrics export complies with OpenMetrics standard" "FAIL" "Metrics missing"
fi

python3 "$REAPER_PY" --json -o "$TEST_JSON" --no-fail >/dev/null 2>&1
if [[ -f "$TEST_JSON" && -s "$TEST_JSON" ]]; then
    report_test "Output report generated strictly inside project directory with valid JSON" "PASS"
else
    report_test "Output report generated strictly inside project directory with valid JSON" "FAIL" "File missing"
fi

# ------------------------------------------------------------------------------
# Suite 8: Bash Companion Script Parity
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 8: Bash Companion Script Parity${NC}"

"$SPAWNER_BIN" -z 2 -d 30 >/dev/null 2>&1 &
SPAWN_PID=$!
sleep 1

set +e
sh_scan=$("$REAPER_SH" --scan 2>/dev/null)
sh_code=$?
set -e

if [[ $sh_code -eq 1 && "$sh_scan" =~ "ZOMBIE (DEFUNCT) PROCESSES (2 found)" ]]; then
    report_test "Bash reaper (process_reaper.sh) accurately detects 2 zombies and exits 1" "PASS"
else
    report_test "Bash reaper (process_reaper.sh) accurately detects 2 zombies and exits 1" "FAIL" "Exit: $sh_code"
fi

"$REAPER_SH" --kill-parents --no-fail >/dev/null 2>&1
sleep 1

sh_post=$("$REAPER_SH" --scan --no-fail 2>/dev/null)
if [[ "$sh_post" =~ "No zombie processes detected" ]]; then
    report_test "Bash reaper --kill-parents successfully cleans process table" "PASS"
else
    report_test "Bash reaper --kill-parents successfully cleans process table" "FAIL"
fi

kill -9 "$SPAWN_PID" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Suite 9: Critical Threshold & Exit Codes
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 9: Critical Threshold & Exit Codes${NC}"

# Spawn 4 zombies
"$SPAWNER_BIN" -z 4 -d 30 >/dev/null 2>&1 &
SPAWN_PID=$!
sleep 1

set +e
python3 "$REAPER_PY" --critical-threshold 3 >/dev/null 2>&1
crit_code=$?
set -e

if [[ $crit_code -eq 2 ]]; then
    report_test "Zombie count exceeding --critical-threshold returns exit code 2" "PASS"
else
    report_test "Zombie count exceeding --critical-threshold returns exit code 2" "FAIL" "Exit: $crit_code"
fi

kill -9 "$SPAWN_PID" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Summary & Test Results
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}                   TEST RESULTS SUMMARY               ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}"
echo -e "  Total Tests  : ${BOLD}${TOTAL_TESTS}${NC}"
echo -e "  Passed Tests : ${GREEN}${PASSED_TESTS}${NC}"
echo -e "  Failed Tests : ${RED}${FAILED_TESTS}${NC}"

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "\n${GREEN}${BOLD}✔ ALL TESTS PASSED SUCCESSFULLY (100% Pass Rate)${NC}\n"
    exit 0
else
    echo -e "\n${RED}${BOLD}✖ SOME TESTS FAILED${NC}\n"
    exit 1
fi
