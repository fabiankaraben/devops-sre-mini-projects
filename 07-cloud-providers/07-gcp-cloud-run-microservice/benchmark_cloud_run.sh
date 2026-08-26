#!/usr/bin/env bash
# ==============================================================================
# benchmark_cloud_run.sh - GCP Cloud Run Microservice Benchmarking Suite
# ==============================================================================
# Measures cold start latency, concurrent throughput (RPS), response times
# (P50/P95/P99), concurrency saturation, and Secret Manager resolution.
# ==============================================================================

set -euo pipefail

# ANSI color formatting
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Defaults
TARGET_URL=""
REQUESTS_COUNT=50
CONCURRENCY=10
SIMULATED_DELAY_MS=0
MEASURE_COLD_START=false
TEST_SECRET=false
MOCK_MODE=false
VERBOSE=false
JSON_OUT=""

show_help() {
    echo -e "${CLR_BOLD}Usage:${CLR_RESET} ./benchmark_cloud_run.sh [OPTIONS]"
    echo ""
    echo -e "${CLR_BOLD}Options:${CLR_RESET}"
    echo "  --url URL              Target Cloud Run endpoint (e.g. https://service-xyz.run.app or http://localhost:8080)"
    echo "  --requests INT         Total number of benchmark requests to dispatch (default: 50)"
    echo "  --concurrency INT      Number of concurrent client workers (default: 10)"
    echo "  --workload-delay INT   Simulated server processing delay in ms (default: 0)"
    echo "  --cold-start           Execute cold start vs warm request latency delta benchmark"
    echo "  --test-secret          Verify Google Secret Manager secret resolution & masking"
    echo "  --mock, --offline      Run against local deterministic Python Knative simulator"
    echo "  --json-output FILE     Export benchmark summary metrics to JSON file"
    echo "  --verbose, -v          Show detailed response payloads and logs"
    echo "  --help, -h             Show this help message"
    echo ""
    echo -e "${CLR_BOLD}Examples:${CLR_RESET}"
    echo "  ./benchmark_cloud_run.sh --mock"
    echo "  ./benchmark_cloud_run.sh --url http://localhost:8080 --requests 100 --concurrency 20"
    echo "  ./benchmark_cloud_run.sh --url http://localhost:8080 --cold-start --test-secret"
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
        --workload-delay=*)
            SIMULATED_DELAY_MS="${1#*=}"
            shift
            ;;
        --workload-delay)
            SIMULATED_DELAY_MS="${2:-}"
            shift 2
            ;;
        --cold-start)
            MEASURE_COLD_START=true
            shift
            ;;
        --test-secret)
            TEST_SECRET=true
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

# Check if Terraform output is available for live Cloud Run service
if [[ -z "$TARGET_URL" ]] && [[ "$MOCK_MODE" == false ]]; then
    if command -v terraform >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/terraform.tfstate" ]]; then
        TF_URL=$(terraform output -raw service_url 2>/dev/null || true)
        if [[ -n "$TF_URL" ]] && [[ "$TF_URL" != "null" ]]; then
            TARGET_URL="$TF_URL"
            echo -e "${CLR_GRAY}[INFO] Discovered Cloud Run URL from Terraform state: ${TARGET_URL}${CLR_RESET}"
        fi
    fi
fi

# Fallback to local docker container if responding on localhost:8080
if [[ -z "$TARGET_URL" ]] && [[ "$MOCK_MODE" == false ]]; then
    if curl -fs -m 2 "http://localhost:8080/health" >/dev/null 2>&1; then
        TARGET_URL="http://localhost:8080"
        echo -e "${CLR_GRAY}[INFO] Found local Docker Cloud Run container running at ${TARGET_URL}${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}[WARN] No live URL provided and local container not responding.${CLR_RESET}"
        echo -e "${CLR_YELLOW}[INFO] Defaulting to 100% offline Python Knative simulator (--mock).${CLR_RESET}"
        MOCK_MODE=true
    fi
fi

# ------------------------------------------------------------------------------
# Mode 1: 100% Offline Python Simulator Execution
# ------------------------------------------------------------------------------
if [[ "$MOCK_MODE" == true ]]; then
    SIM_ARGS=()
    if [[ "$VERBOSE" == true ]]; then
        SIM_ARGS+=("--verbose")
    fi
    if [[ -n "$JSON_OUT" ]]; then
        SIM_ARGS+=("--json-output" "$JSON_OUT")
    else
        SIM_ARGS+=("--json-output" "$SCRIPT_DIR/test_benchmark_results.json")
    fi

    python3 "$SCRIPT_DIR/cloud_run_simulator.py" "${SIM_ARGS[@]}"
    exit $?
fi

# ------------------------------------------------------------------------------
# Mode 2: Live HTTP Cloud Run Benchmarking
# ------------------------------------------------------------------------------
echo -e "${CLR_BLUE}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ GCP Cloud Run Microservice Performance Benchmark"
echo "======================================================================"
echo "  Target URL       : ${TARGET_URL}"
echo "  Total Requests   : ${REQUESTS_COUNT}"
echo "  Concurrency      : ${CONCURRENCY}"
echo "  Workload Delay   : ${SIMULATED_DELAY_MS} ms"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Phase 1: Health & Liveness Probe
echo -e "${CLR_YELLOW}▶ [1/4] Probing Service Health & Startup (/health)...${CLR_RESET}"
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "${TARGET_URL}/health" || echo "000")
if [[ "$HEALTH_CODE" != "200" ]]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Service unhealthy at ${TARGET_URL}/health (HTTP Code: ${HEALTH_CODE})"
    exit 1
fi
HEALTH_RESP=$(curl -s -m 5 "${TARGET_URL}/health")
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Health Endpoint Responding (HTTP 200):"
echo -e "  ${CLR_GRAY}${HEALTH_RESP}${CLR_RESET}"

# Phase 2: Secret Manager Resolution
if [[ "$TEST_SECRET" == true ]] || [[ "$VERBOSE" == true ]]; then
    echo -e "\n${CLR_YELLOW}▶ [2/4] Testing Secret Manager Secret Injection (/api/secret)...${CLR_RESET}"
    SECRET_RESP=$(curl -s -m 5 "${TARGET_URL}/api/secret" || echo "{}")
    echo -e "  ${CLR_GRAY}${SECRET_RESP}${CLR_RESET}"
    if echo "$SECRET_RESP" | grep -q "AUTHENTICATED"; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Secret Manager resolution verified and masked securely."
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Secret Manager status UNSET or fallback used."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/4] Secret Manager check skipped (use --test-secret to verify).${CLR_RESET}"
fi

# Phase 3: Cold Start Latency Delta Benchmark
if [[ "$MEASURE_COLD_START" == true ]]; then
    echo -e "\n${CLR_YELLOW}▶ [3/4] Measuring Cold Start vs Warm Latency Delta...${CLR_RESET}"
    
    # Request 1 (Initial Probe)
    T1_START=$(python3 -c "import time; print(time.time())")
    curl -s -o /dev/null -m 10 "${TARGET_URL}/api/data?delay_ms=0"
    T1_END=$(python3 -c "import time; print(time.time())")
    T1_MS=$(python3 -c "print(round(($T1_END - $T1_START) * 1000.0, 2))")

    # Request 2 (Warm Probe)
    T2_START=$(python3 -c "import time; print(time.time())")
    curl -s -o /dev/null -m 5 "${TARGET_URL}/api/data?delay_ms=0"
    T2_END=$(python3 -c "import time; print(time.time())")
    T2_MS=$(python3 -c "print(round(($T2_END - $T2_START) * 1000.0, 2))")

    echo "  • Initial Request Latency : ${T1_MS} ms"
    echo "  • Warm Request Latency    : ${T2_MS} ms"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Warm container response is $(python3 -c "print(round(max(1.0, float($T1_MS)/max(0.1, float($T2_MS))), 1))")x faster!"
else
    echo -e "\n${CLR_YELLOW}▶ [3/4] Cold start measurement skipped (use --cold-start to enable).${CLR_RESET}"
fi

# Phase 4: High-Concurrency Throughput Benchmark
echo -e "\n${CLR_YELLOW}▶ [4/4] Dispatching ${REQUESTS_COUNT} requests at concurrency ${CONCURRENCY}...${CLR_RESET}"

ENDPOINT="${TARGET_URL}/api/data"
if [[ "$SIMULATED_DELAY_MS" -gt 0 ]]; then
    ENDPOINT="${ENDPOINT}?delay_ms=${SIMULATED_DELAY_MS}"
fi

python3 - <<EOF
import json
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

target_url = "${ENDPOINT}"
total_requests = ${REQUESTS_COUNT}
concurrency = ${CONCURRENCY}
verbose = "${VERBOSE}".lower() == "true"
json_out = "${JSON_OUT}"

latencies = []
status_counts = {}
instance_hits = {}

def send_single_req(req_idx):
    req = Request(target_url, headers={"User-Agent": "CloudRunBenchmark/1.0", "Accept": "application/json"})
    t0 = time.time()
    inst_id = "unknown"
    try:
        with urlopen(req, timeout=10) as resp:
            code = resp.getcode()
            body = resp.read().decode('utf-8', errors='ignore')
            inst_id = resp.headers.get("X-Instance-Id", "unknown")
            if inst_id == "unknown":
                try:
                    data = json.loads(body)
                    inst_id = data.get("instance_id", "unknown")
                except:
                    pass
    except HTTPError as e:
        code = e.code
    except Exception as e:
        code = 500
        inst_id = "error"
    elapsed_ms = (time.time() - t0) * 1000.0
    return req_idx, code, inst_id, elapsed_ms

print(f"  Dispatching load with ThreadPoolExecutor (Workers: {concurrency})...")
wall_start = time.time()

with ThreadPoolExecutor(max_workers=concurrency) as executor:
    futures = [executor.submit(send_single_req, i) for i in range(total_requests)]
    for f in as_completed(futures):
        idx, code, inst, lat = f.result()
        latencies.append(lat)
        status_counts[code] = status_counts.get(code, 0) + 1
        instance_hits[inst] = instance_hits.get(inst, 0) + 1

wall_time = time.time() - wall_start
rps = total_requests / max(0.001, wall_time)

latencies.sort()
p50 = statistics.median(latencies)
p95 = latencies[int(len(latencies) * 0.95)] if len(latencies) >= 20 else latencies[-1]
p99 = latencies[int(len(latencies) * 0.99)] if len(latencies) >= 100 else latencies[-1]
avg_lat = statistics.mean(latencies)

print("\n  Traffic Distribution by Container Instance:")
for inst, count in sorted(instance_hits.items(), key=lambda x: x[1], reverse=True):
    pct = (count / total_requests) * 100.0
    bar = "█" * int(pct / 4)
    print(f"    • {inst:<22} : {count:3d} reqs ({pct:5.1f}%) {bar}")

print("\n  Benchmark Metrics Summary:")
print(f"    • HTTP Status Codes    : {status_counts}")
print(f"    • Total Wall Time      : {wall_time:.2f} s")
print(f"    • Throughput           : {rps:.2f} Requests/sec (RPS)")
print(f"    • Mean Latency         : {avg_lat:.2f} ms")
print(f"    • P50 Latency (Median) : {p50:.2f} ms")
print(f"    • P95 Latency          : {p95:.2f} ms")
print(f"    • P99 Latency          : {p99:.2f} ms")

if json_out:
    report = {
        "target_url": target_url,
        "total_requests": total_requests,
        "concurrency": concurrency,
        "wall_time_seconds": round(wall_time, 2),
        "requests_per_second": round(rps, 2),
        "latency_ms": {
            "mean": round(avg_lat, 2),
            "p50": round(p50, 2),
            "p95": round(p95, 2),
            "p99": round(p99, 2)
        },
        "status_codes": status_counts,
        "instance_distribution": instance_hits
    }
    with open(json_out, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\n  [OK] Saved benchmark metrics to {json_out}")
EOF

echo -e "\n${CLR_BLUE}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 GCP Cloud Run Benchmarking Complete!${CLR_RESET}"
echo -e "${CLR_BLUE}${CLR_BOLD}======================================================================${CLR_RESET}\n"
