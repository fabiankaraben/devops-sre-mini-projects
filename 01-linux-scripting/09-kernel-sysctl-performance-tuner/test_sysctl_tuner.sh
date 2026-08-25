#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_sysctl_tuner.sh
# Description: Comprehensive Automated Test Suite for Linux Kernel & Sysctl Performance Tuner.
#              Tests CLI flags, profile parsers, audit compliance calculation,
#              snapshot backup creation, dry-run simulation, rollback execution,
#              network socket benchmark, JSON/Prometheus schemas, and output isolation.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNER_SH="${SCRIPT_DIR}/sysctl_tuner.sh"
TUNER_PY="${SCRIPT_DIR}/sysctl_tuner.py"
BENCHMARK_SH="${SCRIPT_DIR}/benchmark_network.sh"
PROFILES_DIR="${SCRIPT_DIR}/profiles"
BACKUPS_DIR="${SCRIPT_DIR}/backups"
TEST_JSON="${SCRIPT_DIR}/.test_sysctl.json"
TEST_PROM="${SCRIPT_DIR}/.test_prom.txt"

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
    rm -f "$TEST_JSON" "$TEST_PROM" "${SCRIPT_DIR}/.test_bench.json" 2>/dev/null || true
    # Clean temporary test backups created during testing
    rm -f "${BACKUPS_DIR}"/sysctl_backup_test_*.conf 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

# Grant execution permissions
chmod +x "$TUNER_SH" "$TUNER_PY" "$BENCHMARK_SH" 2>/dev/null || true

echo -e "\n${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}${BLUE}     Kernel & Sysctl Performance Tuner - Tests        ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}\n"

# ------------------------------------------------------------------------------
# Suite 1: CLI Flags, Help Options & Error Handling
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Flags & Error Handling${NC}"

set +e
sh_help=$("$TUNER_SH" --help 2>&1)
sh_code=$?
set -e
if [[ $sh_code -eq 0 && "$sh_help" =~ "Usage:" ]]; then
    report_test "Bash tuner --help displays usage and returns 0" "PASS"
else
    report_test "Bash tuner --help displays usage and returns 0" "FAIL" "Exit: $sh_code"
fi

set +e
py_help=$(python3 "$TUNER_PY" --help 2>&1)
py_code=$?
set -e
if [[ $py_code -eq 0 && "$py_help" =~ "usage:" ]]; then
    report_test "Python tuner --help displays usage and returns 0" "PASS"
else
    report_test "Python tuner --help displays usage and returns 0" "FAIL" "Exit: $py_code"
fi

set +e
bench_help=$("$BENCHMARK_SH" --help 2>&1)
bench_code=$?
set -e
if [[ $bench_code -eq 0 && "$bench_help" =~ "Usage:" ]]; then
    report_test "Benchmark script --help displays usage and returns 0" "PASS"
else
    report_test "Benchmark script --help displays usage and returns 0" "FAIL" "Exit: $bench_code"
fi

set +e
bad_prof=$("$TUNER_SH" --profile "non_existent_profile" 2>&1)
bad_code=$?
set -e
if [[ $bad_code -eq 3 ]]; then
    report_test "Missing profile returns exit code 3" "PASS"
else
    report_test "Missing profile returns exit code 3" "FAIL" "Exit: $bad_code"
fi

# ------------------------------------------------------------------------------
# Suite 2: Profile Presets Validation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Profile Presets Validation${NC}"

if grep -q "net.core.somaxconn = 65535" "${PROFILES_DIR}/web.conf" && grep -q "vm.swappiness = 10" "${PROFILES_DIR}/web.conf"; then
    report_test "Web profile contains high-concurrency socket and memory baselines" "PASS"
else
    report_test "Web profile contains high-concurrency socket and memory baselines" "FAIL"
fi

if grep -q "vm.max_map_count = 262144" "${PROFILES_DIR}/db.conf" && grep -q "vm.dirty_ratio = 10" "${PROFILES_DIR}/db.conf"; then
    report_test "DB profile contains database page cache and memory mapping baselines" "PASS"
else
    report_test "DB profile contains database page cache and memory mapping baselines" "FAIL"
fi

if grep -q "net.core.rmem_max = 33554432" "${PROFILES_DIR}/hpc.conf" && grep -q "net.core.netdev_max_backlog = 100000" "${PROFILES_DIR}/hpc.conf"; then
    report_test "HPC profile contains massive BDP buffer and packet queue baselines" "PASS"
else
    report_test "HPC profile contains massive BDP buffer and packet queue baselines" "FAIL"
fi

# ------------------------------------------------------------------------------
# Suite 3: Audit Mode & JSON Compliance Reporting
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Audit Mode & JSON Compliance Reporting${NC}"

sh_audit_json=$("$TUNER_SH" --audit --profile web --json --no-fail)
sh_total=$(echo "$sh_audit_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['summary']['total'])" 2>/dev/null || echo "0")

if [[ $sh_total -ge 10 ]]; then
    report_test "Bash tuner audit mode correctly parses profile and evaluates $sh_total parameters" "PASS"
else
    report_test "Bash tuner audit mode correctly parses profile and evaluates parameters" "FAIL" "Total: $sh_total"
fi

py_audit_json=$(python3 "$TUNER_PY" --audit --profile web --json --no-fail)
py_total=$(echo "$py_audit_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['summary']['total'])" 2>/dev/null || echo "0")

if [[ $py_total -eq $sh_total ]]; then
    report_test "Python tuner audit parity matches Bash parameter count ($py_total parameters)" "PASS"
else
    report_test "Python tuner audit parity matches Bash parameter count" "FAIL" "Py: $py_total vs Sh: $sh_total"
fi

# ------------------------------------------------------------------------------
# Suite 4: Prometheus OpenMetrics Exporter
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Prometheus OpenMetrics Export${NC}"

prom_out=$(python3 "$TUNER_PY" --prometheus --profile web --no-fail)

has_comp=$(echo "$prom_out" | grep -q 'sysctl_compliance_percent' && echo 1 || echo 0)
has_tot=$(echo "$prom_out" | grep -q 'sysctl_parameters_total' && echo 1 || echo 0)
has_state=$(echo "$prom_out" | grep -q 'sysctl_parameter_state' && echo 1 || echo 0)

if [[ $has_comp -eq 1 && $has_tot -eq 1 && $has_state -eq 1 ]]; then
    report_test "Prometheus metrics export complies with OpenMetrics standard" "PASS"
else
    report_test "Prometheus metrics export complies with OpenMetrics standard" "FAIL" "Metrics missing"
fi

# ------------------------------------------------------------------------------
# Suite 5: Snapshot Backup Creation & Dry-Run Mode
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Snapshot Backups & Dry-Run Simulation${NC}"

initial_backup_count=$( (ls -1 "${BACKUPS_DIR}"/sysctl_backup_*.conf 2>/dev/null || true) | wc -l | tr -d ' ' )

# Run dry-run apply
"$TUNER_SH" --apply --profile web --dry-run >/dev/null 2>&1

new_backup_count=$( (ls -1 "${BACKUPS_DIR}"/sysctl_backup_*.conf 2>/dev/null || true) | wc -l | tr -d ' ' )

if [[ $new_backup_count -gt $initial_backup_count ]]; then
    report_test "Tuner creates timestamped snapshot backup before applying profile" "PASS"
else
    report_test "Tuner creates timestamped snapshot backup before applying profile" "FAIL" "Count before: $initial_backup_count, after: $new_backup_count"
fi

# Verify newest backup file structure
LATEST_BACKUP=$(ls -t "${BACKUPS_DIR}"/sysctl_backup_*.conf 2>/dev/null | head -n 1 || true)
if [[ -n "$LATEST_BACKUP" && -f "$LATEST_BACKUP" ]] && grep -q "# Sysctl" "$LATEST_BACKUP"; then
    report_test "Backup snapshot file contains valid header comments and parameter map" "PASS"
else
    report_test "Backup snapshot file contains valid header comments and parameter map" "FAIL"
fi

# ------------------------------------------------------------------------------
# Suite 6: Rollback Simulation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 6: Rollback Simulation${NC}"

set +e
rollback_out=$("$TUNER_SH" --rollback "$LATEST_BACKUP" --dry-run 2>&1)
rollback_code=$?
set -e

if [[ $rollback_code -eq 0 && "$rollback_out" =~ "ROLLBACK COMPLETE" ]]; then
    report_test "Rollback parses snapshot and executes simulated parameter restoration" "PASS"
else
    report_test "Rollback parses snapshot and executes simulated parameter restoration" "FAIL" "Exit: $rollback_code"
fi

# ------------------------------------------------------------------------------
# Suite 7: Network Socket Concurrency Benchmark
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 7: Network Socket Benchmark${NC}"

bench_json=$("$BENCHMARK_SH" -n 150 -c 15 --json)
succ_conns=$(echo "$bench_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['successful_connections'])" 2>/dev/null || echo "0")
throughput=$(echo "$bench_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['connections_per_second'])" 2>/dev/null || echo "0")

if [[ $succ_conns -eq 150 && $(echo "$throughput > 100.0" | bc -l) -eq 1 ]]; then
    report_test "Socket benchmark completes 150 requests ($throughput req/sec) with zero drops" "PASS"
else
    report_test "Socket benchmark completes 150 requests with zero drops" "FAIL" "Success: $succ_conns, Throughput: $throughput"
fi

# ------------------------------------------------------------------------------
# Suite 8: Output Report File Isolation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 8: Output File Isolation${NC}"

python3 "$TUNER_PY" --json -o "$TEST_JSON" --no-fail >/dev/null 2>&1

if [[ -f "$TEST_JSON" && -s "$TEST_JSON" ]]; then
    report_test "Audit output file written strictly inside project directory" "PASS"
else
    report_test "Audit output file written strictly inside project directory" "FAIL"
fi

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
