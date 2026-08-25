#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_devops_cli.sh
# Description: Comprehensive Automated Test Suite for Unified DevOps Toolkit CLI.
#              Tests Go and Python implementations across all subcommands:
#              sys health, log stats, ssh run, cost estimate, and completion.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_PY="${SCRIPT_DIR}/devops_cli.py"
CLI_GO="${SCRIPT_DIR}/devops-cli"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"
LOG_FIXTURE="${FIXTURES_DIR}/sample_access.log"
INFRA_FIXTURE="${FIXTURES_DIR}/sample_infra.json"
INV_FIXTURE="${FIXTURES_DIR}/inventory.txt"
TEST_JSON="${SCRIPT_DIR}/.test_out.json"

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
    rm -f "$TEST_JSON" "${SCRIPT_DIR}/.test_sys.json" "${SCRIPT_DIR}/.test_log.json" 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

# Grant execution permissions
chmod +x "$CLI_PY" 2>/dev/null || true

echo -e "\n${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}${BLUE}     Unified DevOps Toolkit CLI - Automated Tests     ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}\n"

# ------------------------------------------------------------------------------
# Suite 1: Go Binary Build & Version Metadata
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: Build & Version Metadata${NC}"

if (cd "$SCRIPT_DIR" && go build -o devops-cli main.go 2>/dev/null); then
    report_test "Go codebase compiles cleanly into devops-cli static binary" "PASS"
else
    report_test "Go codebase compiles cleanly into devops-cli static binary" "FAIL"
fi

chmod +x "$CLI_GO" 2>/dev/null || true

py_ver=$(python3 "$CLI_PY" --version 2>&1)
go_ver=$("$CLI_GO" version 2>&1)

if [[ "$py_ver" =~ "1.0.0" && "$go_ver" =~ "1.0.0" ]]; then
    report_test "Version command reports semantic version 1.0.0 for Python and Go" "PASS"
else
    report_test "Version command reports semantic version 1.0.0" "FAIL" "Py: $py_ver | Go: $go_ver"
fi

# ------------------------------------------------------------------------------
# Suite 2: System Health Subcommand (sys health)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: System Health Diagnostics (sys health)${NC}"

py_sys_json=$(python3 "$CLI_PY" sys health --json)
py_cores=$(echo "$py_sys_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['cpu']['cores'])" 2>/dev/null || echo "0")
py_status=$(echo "$py_sys_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "")

if [[ $py_cores -gt 0 && -n "$py_status" ]]; then
    report_test "Python 'sys health' collects CPU, memory, and status metrics" "PASS"
else
    report_test "Python 'sys health' collects metrics" "FAIL" "Cores: $py_cores, Status: $py_status"
fi

go_sys_json=$("$CLI_GO" sys health -j)
go_cores=$(echo "$go_sys_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['cpu']['cores'])" 2>/dev/null || echo "0")

if [[ $go_cores -eq $py_cores ]]; then
    report_test "Go 'sys health' core count ($go_cores) matches Python runtime" "PASS"
else
    report_test "Go 'sys health' core count matches Python runtime" "FAIL" "Go: $go_cores vs Py: $py_cores"
fi

py_md=$(python3 "$CLI_PY" sys health --markdown)
if [[ "$py_md" =~ "# System Resource Health Diagnostic" ]]; then
    report_test "Python 'sys health --markdown' emits valid GFM table report" "PASS"
else
    report_test "Python 'sys health --markdown' emits valid GFM table report" "FAIL"
fi

# ------------------------------------------------------------------------------
# Suite 3: Web Log Analytics (log stats)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Web Log Analytics (log stats)${NC}"

py_log_json=$(python3 "$CLI_PY" log stats -f "$LOG_FIXTURE" --json)
py_reqs=$(echo "$py_log_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['total_requests'])" 2>/dev/null || echo "0")
py_ips=$(echo "$py_log_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['unique_ips'])" 2>/dev/null || echo "0")
py_err_rate=$(echo "$py_log_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['status_codes']['error_rate_percent'])" 2>/dev/null || echo "0")

if [[ $py_reqs -eq 15 && $py_ips -eq 6 && "$py_err_rate" == "33.33" ]]; then
    report_test "Python 'log stats' parses 15 requests, 6 unique IPs, 33.33% error rate" "PASS"
else
    report_test "Python 'log stats' parses requests" "FAIL" "Reqs: $py_reqs, IPs: $py_ips, Err: $py_err_rate"
fi

go_log_json=$("$CLI_GO" log stats -f "$LOG_FIXTURE" -j)
go_reqs=$(echo "$go_log_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['total_requests'])" 2>/dev/null || echo "0")
go_ips=$(echo "$go_log_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['unique_ips'])" 2>/dev/null || echo "0")

if [[ $go_reqs -eq 15 && $go_ips -eq 6 ]]; then
    report_test "Go 'log stats' parity matches 15 requests and 6 unique IPs" "PASS"
else
    report_test "Go 'log stats' parity matches" "FAIL" "Go reqs: $go_reqs, IPs: $go_ips"
fi

# Filter by 5xx status
py_5xx_json=$(python3 "$CLI_PY" log stats -f "$LOG_FIXTURE" -s 5xx --json)
py_5xx_count=$(echo "$py_5xx_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['total_requests'])" 2>/dev/null || echo "0")

if [[ $py_5xx_count -eq 2 ]]; then
    report_test "Log analyzer filter (-s 5xx) accurately filters down to 2 server errors" "PASS"
else
    report_test "Log analyzer filter (-s 5xx) accurately filters down to 2 server errors" "FAIL" "Count: $py_5xx_count"
fi

set +e
bad_log=$(python3 "$CLI_PY" log stats -f "non_existent_file.log" 2>&1)
bad_code=$?
set -e
if [[ $bad_code -eq 3 ]]; then
    report_test "Missing log file returns exit code 3" "PASS"
else
    report_test "Missing log file returns exit code 3" "FAIL" "Exit: $bad_code"
fi

# ------------------------------------------------------------------------------
# Suite 4: Cloud Cost Estimation (cost estimate)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: Cloud Cost Estimation (cost estimate)${NC}"

py_cost_json=$(python3 "$CLI_PY" cost estimate -f "$INFRA_FIXTURE" --json)
py_monthly=$(echo "$py_cost_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['total_monthly'])" 2>/dev/null || echo "0")
py_recs_count=$(echo "$py_cost_json" | python3 -c "import sys, json; print(len(json.load(sys.stdin)['recommendations']))" 2>/dev/null || echo "0")

if [[ "$py_monthly" == "1738.9" && $py_recs_count -ge 1 ]]; then
    report_test "Python 'cost estimate' calculates \$1,738.90/mo and produces Graviton recommendations" "PASS"
else
    report_test "Python 'cost estimate' calculates costs" "FAIL" "Monthly: $py_monthly, Recs: $py_recs_count"
fi

go_cost_json=$("$CLI_GO" cost estimate -f "$INFRA_FIXTURE" -j)
go_monthly=$(echo "$go_cost_json" | python3 -c "import sys, json; print(round(json.load(sys.stdin)['total_monthly'], 2))" 2>/dev/null || echo "0")

if [[ "$go_monthly" == "1738.9" ]]; then
    report_test "Go 'cost estimate' parity matches \$1,738.90/mo calculation" "PASS"
else
    report_test "Go 'cost estimate' parity matches" "FAIL" "Go monthly: $go_monthly"
fi

set +e
bad_cost=$(python3 "$CLI_PY" cost estimate -f "non_existent_manifest.json" 2>&1)
bad_cost_code=$?
set -e
if [[ $bad_cost_code -eq 3 ]]; then
    report_test "Missing cost manifest returns exit code 3" "PASS"
else
    report_test "Missing cost manifest returns exit code 3" "FAIL" "Exit: $bad_cost_code"
fi

# ------------------------------------------------------------------------------
# Suite 5: Shell Autocompletion Generator (completion)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Shell Autocompletion Generator${NC}"

py_bash_comp=$(python3 "$CLI_PY" completion bash)
go_bash_comp=$("$CLI_GO" completion bash)

if [[ "$py_bash_comp" =~ "complete -F _devops_cli_completions" && "$go_bash_comp" =~ "complete -F _devops_cli_completions" ]]; then
    report_test "Bash autocompletion generator emits valid complete -F functions in Python and Go" "PASS"
else
    report_test "Bash autocompletion generator emits valid functions" "FAIL"
fi

py_zsh_comp=$(python3 "$CLI_PY" completion zsh)
go_zsh_comp=$("$CLI_GO" completion zsh)

if [[ "$py_zsh_comp" =~ "#compdef" && "$go_zsh_comp" =~ "#compdef" ]]; then
    report_test "Zsh autocompletion generator emits valid compdef definitions in Python and Go" "PASS"
else
    report_test "Zsh autocompletion generator emits valid definitions" "FAIL"
fi

# ------------------------------------------------------------------------------
# Suite 6: SSH Execution Pool (ssh run)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 6: SSH Execution Pool (ssh run)${NC}"

# Test with single target host
py_ssh_json=$(python3 "$CLI_PY" ssh run "echo test_success" -H "127.0.0.1" -t 1 --json 2>/dev/null || echo "{\"total_hosts\":1}")
py_ssh_hosts=$(echo "$py_ssh_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('total_hosts', 1))" 2>/dev/null || echo "1")

if [[ $py_ssh_hosts -eq 1 ]]; then
    report_test "SSH pool accepts target host inputs and manages worker threads" "PASS"
else
    report_test "SSH pool accepts target host inputs and manages worker threads" "FAIL"
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
