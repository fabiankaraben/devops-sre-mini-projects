#!/usr/bin/env bash
# ==============================================================================
# Error Spike Injector: Generates bursts of HTTP 500 / 502 / 503 errors
# ==============================================================================
set -e

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

TARGET_HOST="127.0.0.1"
TARGET_PORT="8080"
ERROR_COUNT=60
BASELINE_COUNT=15
RATE_DELAY=0.05
CONTINUOUS=false

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --count|-c)
            ERROR_COUNT="$2"
            shift 2
            ;;
        --baseline|-b)
            BASELINE_COUNT="$2"
            shift 2
            ;;
        --port|-p)
            TARGET_PORT="$2"
            shift 2
            ;;
        --host|-h)
            TARGET_HOST="$2"
            shift 2
            ;;
        --delay|-d)
            RATE_DELAY="$2"
            shift 2
            ;;
        --continuous)
            CONTINUOUS=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

BASE_URL="http://${TARGET_HOST}:${TARGET_PORT}"

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  💥 HTTP 500 Error Spike & Telemetry Injector${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

# Verify Nginx target is accessible
if ! curl -s -f -o /dev/null "${BASE_URL}/api/health" 2>/dev/null; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Nginx endpoint ${BASE_URL} is unreachable. Is docker-compose running?"
    exit 1
fi
echo -e "  [${CLR_GREEN}CONNECTED${CLR_RESET}] Target Nginx server is healthy at ${BASE_URL}."

inject_cycle() {
    local cycle_num="$1"
    echo -e "\n${CLR_YELLOW}▶ [Cycle ${cycle_num}] Emitting ${BASELINE_COUNT} baseline 200 OK requests...${CLR_RESET}"
    local count_200=0
    for ((i=1; i<=BASELINE_COUNT; i++)); do
        local ep="/"
        if (( i % 2 == 0 )); then ep="/api/health"; fi
        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}${ep}")
        if [ "$status" -eq 200 ]; then
            count_200=$((count_200 + 1))
        fi
        sleep "$RATE_DELAY"
    done
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Emitted ${count_200}/${BASELINE_COUNT} normal 200 OK transactions."

    echo -e "\n${CLR_RED}${CLR_BOLD}▶ [Cycle ${cycle_num}] INJECTING CRITICAL ERROR SPIKE (${ERROR_COUNT} 5xx requests)...${CLR_RESET}"
    local count_500=0
    local count_502=0
    local count_503=0
    local start_ts
    start_ts=$(date +%s)

    for ((i=1; i<=ERROR_COUNT; i++)); do
        local ep="/api/error"
        local roll=$(( i % 10 ))
        if [ $roll -eq 7 ]; then
            ep="/api/unavailable"
        elif [ $roll -eq 8 ]; then
            ep="/api/gateway-error"
        fi

        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}${ep}")

        if [ "$status" -eq 500 ]; then
            count_500=$((count_500 + 1))
        elif [ "$status" -eq 502 ]; then
            count_502=$((count_502 + 1))
        elif [ "$status" -eq 503 ]; then
            count_503=$((count_503 + 1))
        fi

        # Progress indicator
        if (( i % 15 == 0 )); then
            echo -e "  ${CLR_GRAY}Injected ${i}/${ERROR_COUNT} fault requests (HTTP 500: ${count_500}, 502: ${count_502}, 503: ${count_503})...${CLR_RESET}"
        fi

        sleep "$RATE_DELAY"
    done

    local total_errors=$((count_500 + count_502 + count_503))
    echo -e "  [${CLR_GREEN}INJECTED${CLR_RESET}] Burst complete: ${total_errors} total 5xx errors generated."
}

if [ "$CONTINUOUS" = true ]; then
    echo -e "${CLR_YELLOW}Running in continuous fault injection mode (Press Ctrl+C to stop)...${CLR_RESET}"
    cycle=1
    while true; do
        inject_cycle "$cycle"
        cycle=$((cycle + 1))
        sleep 5
    done
else
    inject_cycle 1
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Fault injection burst finished! Promtail & Loki are extracting metrics.${CLR_RESET}\n"
fi
