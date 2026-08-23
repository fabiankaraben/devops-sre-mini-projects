#!/usr/bin/env bash
# ==============================================================================
# run_performance_suite.sh - Grafana k6 Execution Automation Script
# ==============================================================================
# Executes k6 performance, load, stress, and spike test scripts, streams
# metrics to InfluxDB, and outputs formatted test summaries.
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SCENARIO="load"
TARGET_URL="http://target-api:8080"
LOCAL_TARGET_URL="http://localhost:8080"
USE_INFLUXDB=true
SUMMARY_FILE=""

for arg in "$@"; do
    case "$arg" in
        --scenario=*)
            SCENARIO="${arg#*=}"
            ;;
        --target=*)
            TARGET_URL="${arg#*=}"
            LOCAL_TARGET_URL="${arg#*=}"
            ;;
        --no-influxdb)
            USE_INFLUXDB=false
            ;;
        --summary=*)
            SUMMARY_FILE="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./run_performance_suite.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --scenario=<smoke|load|stress|spike>   Test profile to execute (default: load)"
            echo "  --target=<url>                         Target API URL"
            echo "  --no-influxdb                          Disable InfluxDB metric export"
            echo "  --summary=<file>                       Export JSON summary report"
            echo "  --help, -h                             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run ./run_performance_suite.sh --help for options."
            exit 1
            ;;
    esac
done

SCRIPT_FILE=""
case "$SCENARIO" in
    smoke|smoke_test)
        SCRIPT_FILE="smoke_test.js"
        ;;
    load|load_test)
        SCRIPT_FILE="load_test.js"
        ;;
    stress|stress_test)
        SCRIPT_FILE="stress_test.js"
        ;;
    spike|spike_test)
        SCRIPT_FILE="spike_test.js"
        ;;
    *)
        echo -e "${CLR_RED}Error: Unknown scenario '$SCENARIO'. Choose smoke, load, stress, or spike.${CLR_RESET}"
        exit 1
        ;;
esac

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚀 EXECUTING GRAFANA k6 PERFORMANCE TEST SUITE"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo "  Scenario:     $SCENARIO (scripts/$SCRIPT_FILE)"
echo "  Target URL:   $TARGET_URL"
echo "  InfluxDB:     $USE_INFLUXDB"

K6_ARGS=()
if [ "$USE_INFLUXDB" = true ]; then
    K6_ARGS+=( "--out" "influxdb=http://influxdb:8086/k6" )
fi

if [ -n "$SUMMARY_FILE" ]; then
    K6_ARGS+=( "--summary-export" "/scripts/$SUMMARY_FILE" )
fi

echo -e "\n${CLR_YELLOW}▶ Running k6 test runner inside Docker network 'sre-k6-net'...${CLR_RESET}\n"

# Ensure sre-k6-runner image is built
if ! docker image inspect sre-k6-runner:latest >/dev/null 2>&1; then
    docker build -q -t sre-k6-runner:latest -f Dockerfile.k6 . >/dev/null
fi

# Run k6 containerized within the Docker network
set +e
docker run --rm \
    --network sre-k6-net \
    -e TARGET_URL="$TARGET_URL" \
    sre-k6-runner:latest run \
    "${K6_ARGS[@]}" \
    "/scripts/$SCRIPT_FILE"

K6_EXIT_CODE=$?
set -e

echo -e "\n${CLR_BOLD}======================================================================${CLR_RESET}"
if [ "$K6_EXIT_CODE" -eq 0 ]; then
    echo -e "  [${CLR_GREEN}SUCCESS${CLR_RESET}] k6 performance test completed and all thresholds passed!"
else
    echo -e "  [${CLR_RED}THRESHOLD BREACH${CLR_RESET}] k6 exited with code $K6_EXIT_CODE (SLO threshold failed)."
fi
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}\n"

exit $K6_EXIT_CODE
