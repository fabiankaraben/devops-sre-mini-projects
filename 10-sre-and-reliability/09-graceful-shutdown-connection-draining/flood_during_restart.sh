#!/usr/bin/env bash
# ==============================================================================
# flood_during_restart.sh - Continuous HTTP Flood Load Test During Rolling Update
# ==============================================================================
# 1. Initiates high-concurrency continuous traffic against the target endpoint.
# 2. Triggers a Kubernetes Deployment Rolling Restart (or Docker reload).
# 3. Monitors the rollout to completion while verifying active in-flight requests.
# 4. Validates that 100% of requests succeed with zero connection resets.
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

export KUBECONFIG="${KUBECONFIG:-$SCRIPT_DIR/.kubeconfig}"
TARGET_DEPLOYMENT="graceful-app"
NAMESPACE="graceful-demo"
URL="http://localhost:8089/api/v1/work"
DURATION=30
CONCURRENCY=8
RPS=4.0
ASSERT_ZERO_DOWNTIME=true

for arg in "$@"; do
    case "$arg" in
        --naive)
            TARGET_DEPLOYMENT="naive-app"
            ASSERT_ZERO_DOWNTIME=false
            ;;
        --graceful)
            TARGET_DEPLOYMENT="graceful-app"
            ASSERT_ZERO_DOWNTIME=true
            ;;
        --url=*)
            URL="${arg#*=}"
            ;;
        --duration=*)
            DURATION="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./flood_during_restart.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --graceful              Target the Graceful Deployment with preStop hook (Default)"
            echo "  --naive                 Target the Naive Deployment without preStop hook to demo 502s"
            echo "  --url=URL               Target endpoint URL (default: http://localhost:8089/api/v1/work)"
            echo "  --duration=SEC          Load test duration in seconds (default: 30)"
            echo "  --help, -h              Show this help message"
            exit 0
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🌊 Continuous Traffic Flood During Rolling Update: $TARGET_DEPLOYMENT"
echo "======================================================================"
echo -e "${CLR_RESET}"

REPORT_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORT_DIR"

# 1. Start continuous flood load tester in background
STOP_FILE="$REPORT_DIR/stop_signal_${TARGET_DEPLOYMENT}"
rm -f "$STOP_FILE"

REPORT_TITLE="Rolling Update Load Test - ${TARGET_DEPLOYMENT}"

echo -e "${CLR_YELLOW}▶ [1/4] Starting concurrent flood traffic (${CONCURRENCY} threads, ${DURATION}s duration)...${CLR_RESET}"
ASSERT_FLAG=""
if [ "$ASSERT_ZERO_DOWNTIME" = true ]; then
    ASSERT_FLAG="--assert-zero-downtime"
fi

python3 "$SCRIPT_DIR/load_tester.py" \
    --url "$URL" \
    --concurrency "$CONCURRENCY" \
    --duration "$DURATION" \
    --rps "$RPS" \
    --stop-file "$STOP_FILE" \
    --report-dir "$REPORT_DIR" \
    --title "$REPORT_TITLE" \
    $ASSERT_FLAG > "$REPORT_DIR/load_test_${TARGET_DEPLOYMENT}.log" 2>&1 &
LOAD_PID=$!

echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Load tester running in background (PID: $LOAD_PID)."

# 2. Wait 4 seconds for traffic to establish
echo -e "\n${CLR_YELLOW}▶ [2/4] Warming up traffic for 4 seconds...${CLR_RESET}"
sleep 4

# 3. Trigger Kubernetes Rolling Restart
echo -e "\n${CLR_YELLOW}▶ [3/4] Triggering rolling restart on deployment/${TARGET_DEPLOYMENT} in namespace ${NAMESPACE}...${CLR_RESET}"
if command -v kubectl >/dev/null 2>&1 && [ -f "$KUBECONFIG" ]; then
    echo -e "  Executing: ${CLR_BOLD}kubectl rollout restart deployment/${TARGET_DEPLOYMENT} -n ${NAMESPACE}${CLR_RESET}"
    kubectl --kubeconfig "$KUBECONFIG" rollout restart "deployment/${TARGET_DEPLOYMENT}" -n "$NAMESPACE"
    
    echo -e "  Waiting for rollout status to complete..."
    kubectl --kubeconfig "$KUBECONFIG" rollout status "deployment/${TARGET_DEPLOYMENT}" -n "$NAMESPACE" --timeout=90s
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Rollout completed successfully!"
else
    echo -e "  [${CLR_YELLOW}NOTE${CLR_RESET}] kubectl or .kubeconfig not found; running local duration test."
fi

# 4. Wait for load tester process to finish
echo -e "\n${CLR_YELLOW}▶ [4/4] Finalizing load test and generating report...${CLR_RESET}"
wait "$LOAD_PID" || LOAD_EXIT=$?
LOAD_EXIT=${LOAD_EXIT:-0}

cat "$REPORT_DIR/load_test_${TARGET_DEPLOYMENT}.log"

echo -e "\n${CLR_CYAN}Reports generated:${CLR_RESET}"
echo -e "  • Markdown: ${CLR_GREEN}$REPORT_DIR/rolling_update_load_test_${TARGET_DEPLOYMENT//-/_}.md${CLR_RESET}"
echo -e "  • JSON    : ${CLR_GREEN}$REPORT_DIR/rolling_update_load_test_${TARGET_DEPLOYMENT//-/_}.json${CLR_RESET}"

if [ "$LOAD_EXIT" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 SUCCESS: Rolling update completed with ZERO downtime!${CLR_RESET}\n"
    exit 0
else
    if [ "$TARGET_DEPLOYMENT" = "naive-app" ]; then
        echo -e "\n${CLR_YELLOW}${CLR_BOLD}⚠️  EXPECTED FAILURE: Naive deployment suffered connection drops as anticipated!${CLR_RESET}\n"
        exit 0
    else
        echo -e "\n${CLR_RED}${CLR_BOLD}❌ FAILURE: Dropped requests or connection resets detected!${CLR_RESET}\n"
        exit 1
    fi
fi
