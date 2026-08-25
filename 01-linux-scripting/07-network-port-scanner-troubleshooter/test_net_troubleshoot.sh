#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_net_troubleshoot.sh
# Description: Comprehensive Automated Test Suite for Network Port Scanner & Troubleshooter.
#              Asserts CLI parsing, TCP connect accuracy (OPEN/CLOSED/FILTERED),
#              banner grabbing, DNS benchmarks, speed (<3s), JSON/Markdown schemas,
#              Prometheus metrics, Go scanner parity, and Bash companion parity.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER_PY="${SCRIPT_DIR}/net_troubleshoot.py"
SCANNER_GO="${SCRIPT_DIR}/net_troubleshoot.go"
SCANNER_SH="${SCRIPT_DIR}/net_troubleshoot.sh"
TARGETS_FILE="${SCRIPT_DIR}/targets.txt"
MOCK_COMPOSE="${SCRIPT_DIR}/mock_network_grid/docker-compose.yml"
TEST_MD="${SCRIPT_DIR}/.test_report.md"
TEST_JSON="${SCRIPT_DIR}/.test_report.json"

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
    rm -f "$TEST_MD" "$TEST_JSON" "${SCRIPT_DIR}/.test_prom.txt" 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

echo -e "\n${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}${BLUE}   Network Port Scanner & Troubleshooter - Tests      ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}\n"

# Ensure mock network grid is running
echo -e "${YELLOW}[SETUP] Checking Mock Network Grid containers...${NC}"
if ! curl -s http://localhost:9080 >/dev/null 2>&1; then
    echo -e "Starting Mock Network Grid..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down 2>/dev/null || true
    docker compose -f "$MOCK_COMPOSE" down 2>/dev/null || true
    docker rm -f mock_web_server mock_db_server mock_secure_gateway net_troubleshoot_scanner 2>/dev/null || true
    docker compose -f "$MOCK_COMPOSE" up -d --build --force-recreate
    sleep 2
fi

# Wait for healthy port
for i in {1..10}; do
    if curl -s http://localhost:9080 >/dev/null 2>&1; then
        echo -e "${GREEN}[SETUP] Mock Network Grid is ready and listening on host ports 9080, 9081, 9432, 9379, 9022.${NC}\n"
        break
    fi
    sleep 1
done

# ------------------------------------------------------------------------------
# Suite 1: CLI Arguments, Profiles & Port Range Parsing
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Arguments & Port Range Parsing${NC}"

set +e
help_out=$(python3 "$SCANNER_PY" --help 2>&1)
help_code=$?
set -e
if [[ $help_code -eq 0 && "$help_out" =~ "usage:" ]]; then
    report_test "Python scanner --help displays usage and returns 0" "PASS"
else
    report_test "Python scanner --help displays usage and returns 0" "FAIL" "Exit: $help_code"
fi

set +e
bad_file_out=$(python3 "$SCANNER_PY" -f "non_existent_file_xyz.txt" 2>&1)
bad_file_code=$?
set -e
if [[ $bad_file_code -eq 3 ]]; then
    report_test "Python scanner returns exit code 3 on missing file" "PASS"
else
    report_test "Python scanner returns exit code 3 on missing file" "FAIL" "Exit: $bad_file_code"
fi

set +e
bash_help_out=$("$SCANNER_SH" --help 2>&1)
bash_help_code=$?
set -e
if [[ $bash_help_code -eq 0 && "$bash_help_out" =~ "Usage:" ]]; then
    report_test "Bash scanner --help displays usage and returns 0" "PASS"
else
    report_test "Bash scanner --help displays usage and returns 0" "FAIL" "Exit: $bash_help_code"
fi

# ------------------------------------------------------------------------------
# Suite 2: TCP Connect State Accuracy (OPEN, CLOSED, FILTERED)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: TCP Connect State Accuracy (OPEN, CLOSED, FILTERED)${NC}"

# 1. Open Port Verification (Port 9080 - HTTP)
scan_open_json=$(python3 "$SCANNER_PY" -t 127.0.0.1 -p 9080 --json --no-fail 2>/dev/null)
open_state=$(echo "$scan_open_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['results'][0]['state'])" 2>/dev/null || echo "")
if [[ "$open_state" == "OPEN" ]]; then
    report_test "TCP connect correctly detects OPEN port (9080)" "PASS"
else
    report_test "TCP connect correctly detects OPEN port (9080)" "FAIL" "State: $open_state"
fi

# 2. Closed Port Verification (Port 59999 - Unused)
scan_closed_json=$(python3 "$SCANNER_PY" -t 127.0.0.1 -p 59999 --json --no-fail 2>/dev/null)
closed_state=$(echo "$scan_closed_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['results'][0]['state'])" 2>/dev/null || echo "")
if [[ "$closed_state" == "CLOSED" ]]; then
    report_test "TCP connect correctly detects CLOSED port with RST (59999)" "PASS"
else
    report_test "TCP connect correctly detects CLOSED port with RST (59999)" "FAIL" "State: $closed_state"
fi

# 3. Filtered Port Verification (Unroutable IP 192.0.2.1)
scan_filt_json=$(python3 "$SCANNER_PY" -t 192.0.2.1 -p 80 --timeout 0.3 --json --no-fail 2>/dev/null)
filt_state=$(echo "$scan_filt_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['results'][0]['state'])" 2>/dev/null || echo "")
if [[ "$filt_state" == "FILTERED" ]]; then
    report_test "TCP connect correctly detects FILTERED port upon timeout (192.0.2.1:80)" "PASS"
else
    report_test "TCP connect correctly detects FILTERED port upon timeout (192.0.2.1:80)" "FAIL" "State: $filt_state"
fi

# ------------------------------------------------------------------------------
# Suite 3: Service Banner Grabbing
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Service Banner Grabbing${NC}"

scan_grid_json=$(python3 "$SCANNER_PY" -t 127.0.0.1 -p 9080,9022,9432,9379 --json --no-fail 2>/dev/null)

nginx_banner=$(echo "$scan_grid_json" | python3 -c "import sys, json; r=json.load(sys.stdin)['results']; print(next((x['banner'] for x in r if x['port']==9080), ''))")
ssh_banner=$(echo "$scan_grid_json" | python3 -c "import sys, json; r=json.load(sys.stdin)['results']; print(next((x['banner'] for x in r if x['port']==9022), ''))")
pg_banner=$(echo "$scan_grid_json" | python3 -c "import sys, json; r=json.load(sys.stdin)['results']; print(next((x['banner'] for x in r if x['port']==9432), ''))")
redis_banner=$(echo "$scan_grid_json" | python3 -c "import sys, json; r=json.load(sys.stdin)['results']; print(next((x['banner'] for x in r if x['port']==9379), ''))")

if [[ "$nginx_banner" =~ "nginx" ]]; then
    report_test "Banner grab correctly identifies HTTP Nginx server header (9080)" "PASS"
else
    report_test "Banner grab correctly identifies HTTP Nginx server header (9080)" "FAIL" "Banner: $nginx_banner"
fi

if [[ "$ssh_banner" =~ "SSH-2.0-OpenSSH" ]]; then
    report_test "Banner grab correctly identifies SSH daemon version (9022)" "PASS"
else
    report_test "Banner grab correctly identifies SSH daemon version (9022)" "FAIL" "Banner: $ssh_banner"
fi

if [[ "$pg_banner" =~ "PostgreSQL" ]]; then
    report_test "Banner grab correctly identifies PostgreSQL protocol (9432)" "PASS"
else
    report_test "Banner grab correctly identifies PostgreSQL protocol (9432)" "FAIL" "Banner: $pg_banner"
fi

if [[ "$redis_banner" =~ "Redis" ]]; then
    report_test "Banner grab correctly identifies Redis key-value store (9379)" "PASS"
else
    report_test "Banner grab correctly identifies Redis key-value store (9379)" "FAIL" "Banner: $redis_banner"
fi

# ------------------------------------------------------------------------------
# Suite 4: DNS Resolution Benchmark
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 4: DNS Resolution Benchmark${NC}"

dns_scan_json=$(python3 "$SCANNER_PY" -t localhost -p 9080 --json --no-fail 2>/dev/null)
dns_hostname=$(echo "$dns_scan_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['dns_benchmarks'][0]['hostname'])" 2>/dev/null || echo "")
dns_latency=$(echo "$dns_scan_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['dns_benchmarks'][0]['latency_ms'])" 2>/dev/null || echo "-1")

if [[ "$dns_hostname" == "localhost" && $(echo "$dns_latency >= 0" | bc -l) -eq 1 ]]; then
    report_test "DNS benchmark accurately resolves hostname and records latency ($dns_latency ms)" "PASS"
else
    report_test "DNS benchmark accurately resolves hostname and records latency" "FAIL" "Host: $dns_hostname, Latency: $dns_latency"
fi

# ------------------------------------------------------------------------------
# Suite 5: Markdown Report & Output File Isolation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 5: Markdown & Output Report Generation${NC}"

python3 "$SCANNER_PY" -t 127.0.0.1 -p 9080,9081 -m -o "$TEST_MD" --no-fail >/dev/null 2>&1

if [[ -f "$TEST_MD" && -s "$TEST_MD" ]]; then
    if grep -q "## Port Status Diagnostics" "$TEST_MD" && grep -q "9080" "$TEST_MD"; then
        report_test "Markdown report file generated strictly in project directory with GFM tables" "PASS"
    else
        report_test "Markdown report file generated strictly in project directory with GFM tables" "FAIL" "Content missing"
    fi
else
    report_test "Markdown report file generated strictly in project directory with GFM tables" "FAIL" "File not created"
fi

# ------------------------------------------------------------------------------
# Suite 6: Prometheus Metrics Export
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 6: Prometheus Metrics Export${NC}"

prom_out=$(python3 "$SCANNER_PY" -t 127.0.0.1 -p 9080,59999 --prometheus --no-fail 2>/dev/null)

has_port_state=$(echo "$prom_out" | grep -q 'net_port_state{host="127.0.0.1",port="9080"' && echo 1 || echo 0)
has_rtt=$(echo "$prom_out" | grep -q 'net_port_rtt_seconds{host="127.0.0.1"' && echo 1 || echo 0)
has_total_metric=$(echo "$prom_out" | grep -q 'net_scan_total_ports 2' && echo 1 || echo 0)

if [[ $has_port_state -eq 1 && $has_rtt -eq 1 && $has_total_metric -eq 1 ]]; then
    report_test "Prometheus metrics exporter complies with OpenMetrics standard" "PASS"
else
    report_test "Prometheus metrics exporter complies with OpenMetrics standard" "FAIL" "Missing metrics"
fi

# ------------------------------------------------------------------------------
# Suite 7: Speed Benchmark (< 3.0 seconds for entire grid)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 7: Scan Performance Benchmark (< 3.0s)${NC}"

start_time=$(date +%s%N 2>/dev/null || date +%s)
python3 "$SCANNER_PY" -t 127.0.0.1 -p 9000-9100 -c 100 --no-fail >/dev/null 2>&1
end_time=$(date +%s%N 2>/dev/null || date +%s)

# Calculate duration
if [[ ${#start_time} -gt 10 ]]; then
    duration_s=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc -l)
else
    duration_s=$((end_time - start_time))
fi

if [[ $(echo "$duration_s < 3.0" | bc -l) -eq 1 ]]; then
    report_test "Concurrent scan over 101 ports completed in ${duration_s}s (< 3.0s threshold)" "PASS"
else
    report_test "Concurrent scan over 101 ports completed in ${duration_s}s (< 3.0s threshold)" "FAIL" "Time: ${duration_s}s"
fi

# ------------------------------------------------------------------------------
# Suite 8: Go Scanner Parity
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 8: Go Scanner Parity${NC}"

set +e
go_json=$(go run "$SCANNER_GO" -t 127.0.0.1 -p 9080,59999 --json --no-fail 2>/dev/null)
go_code=$?
set -e

go_open_p=$(echo "$go_json" | python3 -c "import sys, json; r=json.load(sys.stdin)['results']; print(next((x['state'] for x in r if x['port']==9080), ''))" 2>/dev/null || echo "")
go_closed_p=$(echo "$go_json" | python3 -c "import sys, json; r=json.load(sys.stdin)['results']; print(next((x['state'] for x in r if x['port']==59999), ''))" 2>/dev/null || echo "")

if [[ $go_code -eq 0 && "$go_open_p" == "OPEN" && "$go_closed_p" == "CLOSED" ]]; then
    report_test "Go scanner implementation (net_troubleshoot.go) matches Python accuracy" "PASS"
else
    report_test "Go scanner implementation (net_troubleshoot.go) matches Python accuracy" "FAIL" "Open: $go_open_p, Closed: $go_closed_p"
fi

# ------------------------------------------------------------------------------
# Suite 9: Bash Companion Script Parity
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 9: Bash Companion Script Parity${NC}"

set +e
bash_out=$("$SCANNER_SH" -t 127.0.0.1 -p 9080,59999 2>/dev/null)
bash_code=$?
set -e

if [[ $bash_code -eq 0 && "$bash_out" =~ "[ OPEN  ]" && "$bash_out" =~ "[CLOSED ]" ]]; then
    report_test "Bash scanner (net_troubleshoot.sh) accurately detects open and closed ports" "PASS"
else
    report_test "Bash scanner (net_troubleshoot.sh) accurately detects open and closed ports" "FAIL" "Output: $bash_out"
fi

# ------------------------------------------------------------------------------
# Suite 10: SRE Assertion Flag (--require-open) & Exit Codes
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 10: SRE Assertion Flag (--require-open) & Exit Codes${NC}"

set +e
python3 "$SCANNER_PY" -t 127.0.0.1 -p 9080 --require-open 9080 >/dev/null 2>&1
req_open_code=$?

python3 "$SCANNER_PY" -t 127.0.0.1 -p 59999 --require-open 59999 >/dev/null 2>&1
req_closed_code=$?
set -e

if [[ $req_open_code -eq 0 && $req_closed_code -eq 1 ]]; then
    report_test "--require-open exits 0 when port is OPEN and exits 1 when CLOSED" "PASS"
else
    report_test "--require-open exits 0 when port is OPEN and exits 1 when CLOSED" "FAIL" "Open code: $req_open_code, Closed code: $req_closed_code"
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
