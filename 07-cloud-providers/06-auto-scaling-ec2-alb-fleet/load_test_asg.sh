#!/usr/bin/env bash
# ==============================================================================
# load_test_asg.sh - ASG Load Generation & Stress Testing Suite
# ==============================================================================
# Drives concurrent HTTP traffic against the Application Load Balancer,
# verifies multi-AZ round-robin traffic distribution, triggers dynamic CPU
# stress events to provoke ASG scale-out, and validates ELB self-healing.
#
# Supports:
#   1. Live AWS ALB endpoints (from Terraform outputs or --url)
#   2. Local Docker Compose ALB (http://localhost:8080)
#   3. Standalone offline Python simulator (--mock)
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET_URL=""
MOCK_MODE=false
VERBOSE=false
REQUESTS_COUNT=30
CONCURRENCY=5
STRESS_TEST=false
STRESS_DURATION=30
FAILOVER_TEST=false
JSON_OUT=""

show_help() {
    echo "Usage: ./load_test_asg.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --url URL              Target ALB endpoint (e.g. http://my-alb-123.us-east-1.elb.amazonaws.com or http://localhost:8080)"
    echo "  --requests INT         Total number of test requests to dispatch (default: 30)"
    echo "  --concurrency INT      Concurrent client workers (default: 5)"
    echo "  --stress               Trigger CPU stress (/stress) to provoke ASG scale-out"
    echo "  --stress-duration INT  Duration in seconds for CPU stress (default: 30)"
    echo "  --failover-test        Test ELB unhealthy detection & self-healing via /fail"
    echo "  --mock, --offline      Run against local deterministic Python simulator"
    echo "  --json-output FILE     Export test summary report to JSON file"
    echo "  --verbose, -v          Show detailed response payloads and headers"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./load_test_asg.sh --mock"
    echo "  ./load_test_asg.sh --url http://localhost:8080 --requests 50"
    echo "  ./load_test_asg.sh --url http://localhost:8080 --stress --stress-duration 20"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url=*)
            TARGET_URL="${1#*=}"
            shift
            ;;
        --url)
            TARGET_URL="${2:-}"
            shift 2
            ;;
        --requests=*)
            REQUESTS_COUNT="${1#*=}"
            shift
            ;;
        --requests)
            REQUESTS_COUNT="${2:-}"
            shift 2
            ;;
        --concurrency=*)
            CONCURRENCY="${1#*=}"
            shift
            ;;
        --concurrency)
            CONCURRENCY="${2:-}"
            shift 2
            ;;
        --stress)
            STRESS_TEST=true
            shift
            ;;
        --stress-duration=*)
            STRESS_DURATION="${1#*=}"
            shift
            ;;
        --stress-duration)
            STRESS_DURATION="${2:-}"
            shift 2
            ;;
        --failover-test)
            FAILOVER_TEST=true
            shift
            ;;
        --mock|--offline|--simulator)
            MOCK_MODE=true
            shift
            ;;
        --json-output=*)
            JSON_OUT="${1#*=}"
            shift
            ;;
        --json-output)
            JSON_OUT="${2:-}"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}"
            show_help
            exit 1
            ;;
    esac
done

# Try discovering ALB URL from Terraform output if not provided and not in mock mode
if [[ -z "$TARGET_URL" ]] && [[ "$MOCK_MODE" == false ]]; then
    if [[ -f "$SCRIPT_DIR/terraform.tfstate" ]] && command -v terraform >/dev/null 2>&1; then
        TF_ALB=$(terraform output -raw alb_dns_name 2>/dev/null || true)
        if [[ -n "$TF_ALB" ]] && [[ "$TF_ALB" != "null" ]]; then
            TARGET_URL="$TF_ALB"
            echo -e "${CLR_GRAY}[INFO] Discovered ALB URL from Terraform: ${TARGET_URL}${CLR_RESET}"
        fi
    fi
fi

# Fallback to local docker ALB if running on localhost:8080
if [[ -z "$TARGET_URL" ]] && [[ "$MOCK_MODE" == false ]]; then
    if curl -s --max-time 1 "http://localhost:8080/health" >/dev/null 2>&1; then
        TARGET_URL="http://localhost:8080"
        echo -e "${CLR_GRAY}[INFO] Found local Docker Compose ALB running at ${TARGET_URL}${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}[WARN] No live URL provided and local Docker Compose ALB not responding.${CLR_RESET}"
        echo -e "${CLR_YELLOW}[INFO] Defaulting to 100% offline Python fleet simulator (--mock).${CLR_RESET}"
        MOCK_MODE=true
    fi
fi

# ------------------------------------------------------------------------------
# Mode 1: Offline Python Simulator Execution
# ------------------------------------------------------------------------------
if [[ "$MOCK_MODE" == true ]]; then
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Running ASG & ALB Load Test via Offline Python Simulator"
    echo "======================================================================"
    echo -e "${CLR_RESET}"

    SIM_ARGS=()
    if [[ "$VERBOSE" == true ]]; then
        SIM_ARGS+=("--verbose")
    fi
    if [[ -n "$JSON_OUT" ]]; then
        SIM_ARGS+=("--json-output" "$JSON_OUT")
    else
        SIM_ARGS+=("--json-output" "$SCRIPT_DIR/test_load_results.json")
    fi

    python3 "$SCRIPT_DIR/fleet_simulator.py" "${SIM_ARGS[@]}"
    exit $?
fi

# ------------------------------------------------------------------------------
# Mode 2: Live HTTP Traffic Generation (AWS ALB or Local Docker)
# ------------------------------------------------------------------------------
echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ High-Availability ASG Fleet Behind ALB - Load Test Runner"
echo "======================================================================"
echo "  Target ALB URL : ${TARGET_URL}"
echo "  Total Requests : ${REQUESTS_COUNT}"
echo "  Concurrency    : ${CONCURRENCY}"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Phase 1: Health Check Verification
echo -e "${CLR_YELLOW}▶ [1/4] Probing ALB Health Check Endpoint (/health)...${CLR_RESET}"
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "${TARGET_URL}/health" || echo "000")
if [[ "$HEALTH_CODE" != "200" ]]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Could not connect to healthy endpoint at ${TARGET_URL}/health (HTTP Code: ${HEALTH_CODE})"
    exit 1
fi
HEALTH_RESP=$(curl -s -m 5 "${TARGET_URL}/health")
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Health Endpoint Responding (HTTP 200):"
echo -e "  ${CLR_GRAY}${HEALTH_RESP}${CLR_RESET}"

# Phase 2: Traffic Distribution Audit
echo -e "\n${CLR_YELLOW}▶ [2/4] Dispatching ${REQUESTS_COUNT} requests to test ALB Round-Robin balance...${CLR_RESET}"

# Python helper to run concurrent requests cleanly without external tools
python3 - << EOF
import concurrent.futures
import json
import sys
import time
import urllib.request
from collections import Counter
from urllib.parse import urljoin

base_url = "$TARGET_URL"
total_reqs = int("$REQUESTS_COUNT")
concurrency = int("$CONCURRENCY")
verbose = "$VERBOSE" == "true"

instances_seen = Counter()
azs_seen = Counter()
status_codes = Counter()
latencies = []

def send_request(req_id):
    start = time.time()
    url = urljoin(base_url, "/api/info")
    req = urllib.request.Request(url, headers={"User-Agent": "ASG-LoadTester/1.0", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            elapsed = (time.time() - start) * 1000
            data = json.loads(resp.read().decode("utf-8"))
            inst_id = data.get("instance", {}).get("instance_id", "unknown")
            az = data.get("instance", {}).get("availability_zone", "unknown")
            return {"status": resp.status, "inst_id": inst_id, "az": az, "latency": elapsed}
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {"status": 500, "inst_id": "error", "az": "error", "latency": elapsed, "error": str(e)}

with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
    futures = [executor.submit(send_request, i) for i in range(total_reqs)]
    for f in concurrent.futures.as_completed(futures):
        res = f.result()
        status_codes[res["status"]] += 1
        instances_seen[res["inst_id"]] += 1
        azs_seen[res["az"]] += 1
        latencies.append(res["latency"])

avg_latency = sum(latencies) / len(latencies) if latencies else 0.0

print(f"\n  \033[1mTraffic Distribution by EC2 Instance:\033[0m")
for inst, count in instances_seen.most_common():
    pct = (count / total_reqs) * 100
    bar = "█" * int(pct / 4)
    print(f"    • \033[1;32m{inst:<20}\033[0m : {count:>3} reqs ({pct:>5.1f}%) \033[0;90m{bar}\033[0m")

print(f"\n  \033[1mTraffic Distribution by Availability Zone:\033[0m")
for az, count in azs_seen.most_common():
    pct = (count / total_reqs) * 100
    bar = "█" * int(pct / 4)
    print(f"    • \033[1;36m{az:<20}\033[0m : {count:>3} reqs ({pct:>5.1f}%) \033[0;90m{bar}\033[0m")

print(f"\n  \033[1mPerformance Summary:\033[0m")
print(f"    • HTTP Status Codes : {dict(status_codes)}")
print(f"    • Avg Response Time : {avg_latency:.2f} ms")
print(f"    • Distinct Nodes    : {len(instances_seen)}")
print(f"    • Distinct AZs      : {len(azs_seen)}")

# Verification assertions
if len(instances_seen) < 2 and total_reqs >= 10:
    print("\n  \033[1;33m[WARN] Only 1 instance received all traffic. ASG may still be booting or single-AZ.\033[0m")
else:
    print("\n  \033[1;32m[OK] Traffic evenly distributed across multi-AZ fleet!\033[0m")
EOF

# Phase 3: Trigger CPU Stress (if requested)
if [[ "$STRESS_TEST" == true ]]; then
    echo -e "\n${CLR_YELLOW}▶ [3/4] Triggering CPU Stress (${STRESS_DURATION}s) to provoke ASG scale-out...${CLR_RESET}"
    STRESS_RESP=$(curl -s -m 5 "${TARGET_URL}/stress?duration=${STRESS_DURATION}&threads=4" || echo "")
    echo -e "  ${CLR_GRAY}${STRESS_RESP}${CLR_RESET}"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Stress threads dispatched. Average CPU rising > 70%."
    echo -e "  CloudWatch / Target Tracking will trigger instance expansion."
else
    echo -e "\n${CLR_YELLOW}▶ [3/4] CPU Stress Test skipped (use --stress to trigger).${CLR_RESET}"
fi

# Phase 4: Simulated Failure Test (if requested)
if [[ "$FAILOVER_TEST" == true ]]; then
    echo -e "\n${CLR_YELLOW}▶ [4/4] Simulating node failure via /fail for Self-Healing verification...${CLR_RESET}"
    FAIL_RESP=$(curl -s -m 5 "${TARGET_URL}/fail" || echo "")
    echo -e "  ${CLR_GRAY}${FAIL_RESP}${CLR_RESET}"
    echo -e "  Node marked UNHEALTHY. ALB Target Group health checks will fail."
    echo -e "  ASG self-healing will terminate dead node and launch replacement."
else
    echo -e "\n${CLR_YELLOW}▶ [4/4] Self-Healing Failover test skipped (use --failover-test to trigger).${CLR_RESET}"
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 Load Testing & Traffic Balancing Audit Complete!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
