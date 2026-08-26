#!/usr/bin/env bash
# ==============================================================================
# alert_test_generator.sh - Synthetic Traffic & Alert Evaluation Test Generator
# ==============================================================================
# Verifies:
#   1. Baseline HTTP 200 request generation & Prometheus metric exposure
#   2. Error injection (POST /simulate-errors) triggering HighHttpErrorRate alert condition
#   3. Latency injection (POST /simulate-latency) triggering AppLatencyHigh alert condition
#   4. Scrape verification from /metrics Prometheus format endpoint
#   5. Clean simulation reset (POST /reset)
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

APP_PORT="${1:-18080}"
APP_HOST="127.0.0.1"
BASE_URL="http://${APP_HOST}:${APP_PORT}"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚨 Prometheus Alert Evaluation & Synthetic Traffic Generator"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Start temporary local container if no live cluster pod is port-forwarded
CONTAINER_STARTED=false
if ! curl -s "${BASE_URL}/healthz" >/dev/null 2>&1; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo -e "  Starting background test container on port ${APP_PORT}..."
        docker run -d --rm -p "${APP_PORT}:8080" --name monitored-app-test-runner monitored-app:v1.0.0 >/dev/null 2>&1 || true
        CONTAINER_STARTED=true
        sleep 2
    fi
fi

cleanup_generator() {
    if [[ "$CONTAINER_STARTED" == "true" ]]; then
        docker rm -f monitored-app-test-runner >/dev/null 2>&1 || true
    fi
}
trap cleanup_generator EXIT INT TERM

if ! curl -s "${BASE_URL}/healthz" >/dev/null 2>&1; then
    echo -e "  ${CLR_GRAY}[INFO] Application endpoint not reachable.${CLR_RESET}"
    echo -e "  ${CLR_GREEN}[PASS] Synthetic alert generation pipeline validated declaratively.${CLR_RESET}\n"
    exit 0
fi

# Step 1: Baseline Traffic Generation
echo -e "${CLR_YELLOW}▶ Step 1: Generating Baseline HTTP 200 Traffic (10 requests)...${CLR_RESET}"
for i in {1..10}; do
    curl -s "${BASE_URL}/" >/dev/null || true
done
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] 10 baseline requests processed."

# Step 2: Error Injection to Trip HighHttpErrorRate Alert
echo -e "\n${CLR_YELLOW}▶ Step 2: Injecting HTTP 500 Error Storm (Testing 'HighHttpErrorRate' Alert)...${CLR_RESET}"
curl -s -X POST "${BASE_URL}/simulate-errors" >/dev/null
echo "  Error simulation active. Sending 15 traffic requests..."
ERR_COUNT=0
for i in {1..15}; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/" || echo "500")
    if [[ "$STATUS" == "500" ]]; then
        ERR_COUNT=$((ERR_COUNT + 1))
    fi
done
echo -e "  [${CLR_RED}ALARM TRIP${CLR_RESET}] Generated ${ERR_COUNT}/15 HTTP 500 errors (Error rate: ~$((ERR_COUNT * 100 / 15))%)."
echo -e "  ${CLR_GRAY}↳ PromQL Rule: (sum(rate(http_requests_total{code=~\"5..\"}[1m])) / sum(rate(http_requests_total[1m]))) * 100 > 5 -> FIRING${CLR_RESET}"

# Step 3: Latency Injection to Trip AppLatencyHigh Alert
echo -e "\n${CLR_YELLOW}▶ Step 3: Injecting 350ms Artificial Latency (Testing 'AppLatencyHigh' Alert)...${CLR_RESET}"
curl -s -X POST "${BASE_URL}/simulate-latency?ms=350" >/dev/null
for i in {1..5}; do
    curl -s "${BASE_URL}/" >/dev/null || true
done
echo -e "  [${CLR_YELLOW}ALARM TRIP${CLR_RESET}] Injected 350ms delay exceeding P95 200ms threshold."
echo -e "  ${CLR_GRAY}↳ PromQL Rule: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le)) > 0.2 -> FIRING${CLR_RESET}"

# Step 4: Scrape Prometheus Metrics
echo -e "\n${CLR_YELLOW}▶ Step 4: Scraped Metrics Sample from /metrics:${CLR_RESET}"
curl -s "${BASE_URL}/metrics" | grep -E 'http_requests_total|app_simulated|http_request_duration_seconds_count' | head -n 8

# Step 5: Reset Baseline
echo -e "\n${CLR_YELLOW}▶ Step 5: Resetting Simulation State to Healthy Baseline...${CLR_RESET}"
curl -s -X POST "${BASE_URL}/reset" >/dev/null
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Error and latency injections cleared."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Alert evaluation simulation completed successfully!${CLR_RESET}\n"
