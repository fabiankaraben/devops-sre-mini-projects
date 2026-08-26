#!/usr/bin/env bash
# ==============================================================================
# Log-Based Metrics Extraction and Alerting - Automated Test Runner
# ==============================================================================
set -e

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  🚨 Log-Based Metrics Extraction & Alerting - Test Suite${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

# ------------------------------------------------------------------------------
# 1. System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker is not installed or not in PATH."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker engine is active."

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker Compose is required."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose: ${COMPOSE_CMD}"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is required."
    exit 1
fi
PYTHON_VER=$(python3 --version 2>&1)
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python runtime: ${PYTHON_VER}"

# ------------------------------------------------------------------------------
# 2. Build & Launch Multi-Service Observability Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building & Starting Observability Stack (Nginx, Promtail, Loki, Prometheus, Alertmanager)...${CLR_RESET}"

$COMPOSE_CMD build
$COMPOSE_CMD up -d --remove-orphans

echo -e "  Waiting for all 5 services to become healthy..."

MAX_WAIT=90
RETRY=0
ALL_READY=false

while [ $RETRY -lt $MAX_WAIT ]; do
    NGINX_OK=$(curl -s -f -o /dev/null "http://127.0.0.1:8080/api/health" 2>/dev/null && echo "yes" || echo "no")
    PROMTAIL_OK=$(curl -s -f -o /dev/null "http://127.0.0.1:9085/ready" 2>/dev/null && echo "yes" || echo "no")
    LOKI_OK=$(curl -s -f -o /dev/null "http://127.0.0.1:3100/ready" 2>/dev/null && echo "yes" || echo "no")
    PROM_OK=$(curl -s -f -o /dev/null "http://127.0.0.1:9090/-/healthy" 2>/dev/null && echo "yes" || echo "no")
    AM_OK=$(curl -s -f -o /dev/null "http://127.0.0.1:9093/-/healthy" 2>/dev/null && echo "yes" || echo "no")

    if [ "$NGINX_OK" = "yes" ] && [ "$PROMTAIL_OK" = "yes" ] && [ "$LOKI_OK" = "yes" ] && [ "$PROM_OK" = "yes" ] && [ "$AM_OK" = "yes" ]; then
        ALL_READY=true
        echo -e "  [${CLR_GREEN}READY${CLR_RESET}] Nginx (:8080), Promtail (:9085), Loki (:3100), Prometheus (:9090), Alertmanager (:9093) are online."
        break
    fi

    sleep 2
    RETRY=$((RETRY + 2))
    echo -e "  ${CLR_GRAY}Initializing services (${RETRY}s/${MAX_WAIT}s)...${CLR_RESET}"
done

if [ "$ALL_READY" = false ]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] One or more services failed to initialize in ${MAX_WAIT}s."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Inject Baseline Traffic & Error Spike Burst
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Injecting Traffic Baseline & 500 Error Burst...${CLR_RESET}"
./error_spike_injector.sh --count 80 --baseline 20 --delay 0.02

# ------------------------------------------------------------------------------
# 4. Wait for Metric Scraping & Alert Evaluation Cycle
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Allowing Promtail scraping & Prometheus/Loki evaluation cycle (10s)...${CLR_RESET}"
sleep 10

# ------------------------------------------------------------------------------
# 5. Execute Automated Verification Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Running End-to-End Metric & Alert Verification Suite...${CLR_RESET}"
python3 verify_alerts.py

echo -e "\n${CLR_YELLOW}▶ Visual Web UIs Available:${CLR_RESET}"
echo -e "  ${CLR_CYAN}👉 Prometheus Alerts UI:${CLR_RESET}   http://localhost:9090/alerts"
echo -e "  ${CLR_CYAN}👉 Prometheus Graph UI:${CLR_RESET}    http://localhost:9090/graph?g0.expr=sum(rate(promtail_custom_nginx_http_requests_total%7Bstatus%3D~%225..%22%7D%5B1m%5D))"
echo -e "  ${CLR_CYAN}👉 Alertmanager UI:${CLR_RESET}        http://localhost:9093"
echo -e "  ${CLR_CYAN}👉 Nginx Web Application:${CLR_RESET}  http://localhost:8080\n"

echo -e "${CLR_GREEN}${CLR_BOLD}✨ Log-Based Metrics Extraction and Alerting tests completed successfully!${CLR_RESET}\n"
