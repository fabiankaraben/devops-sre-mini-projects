#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Master Automated E2E Runner for Mini-Project 08-10
# ==============================================================================
# 1. Validates local tool prerequisites (Docker, Docker Compose, curl, python3).
# 2. Builds and orchestrates all containers (Target Store, Playwright Agent,
#    Prometheus, Grafana) using Docker Compose.
# 3. Awaits healthiness across all service endpoints.
# 4. Executes test_synthetic_monitoring.sh (baseline, latency chaos, failure
#    screenshot capture, Prometheus alert state changes, and recovery).
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🎭 Playwright Synthetic Journey Monitoring - Master Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Tool Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Checking Tool Prerequisites...${CLR_RESET}"

for tool in docker curl python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Required tool '$tool' is not installed."
        exit 1
    fi
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Tool '$tool' is available."
done

if docker compose version >/dev/null 2>&1; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose plugin is available."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker Compose plugin is required."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Build & Launch Docker Compose Services
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/4] Building & Launching Synthetic Monitoring Stack...${CLR_RESET}"

docker compose down -v >/dev/null 2>&1 || true
docker compose build
docker compose up -d

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Containers deployed in background."

# ------------------------------------------------------------------------------
# 3. Await Container Health Probes
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Awaiting Service Health Probes...${CLR_RESET}"

SERVICES=("target-app" "synthetic-agent" "prometheus" "grafana")
for service in "${SERVICES[@]}"; do
    echo -n "  Waiting for service '$service' to be healthy..."
    for _ in {1..30}; do
        HEALTH_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' "synthetic-$service" 2>/dev/null || echo "\"starting\"")
        if [[ "$HEALTH_STATUS" == "\"healthy\"" ]]; then
            echo -e " [${CLR_GREEN}HEALTHY${CLR_RESET}]"
            break
        fi
        sleep 2
    done
done

# Short warmup pause for initial synthetic baseline cycle
echo "  Allowing initial synthetic run to complete (6s)..."
sleep 6

# ------------------------------------------------------------------------------
# 4. Execute Assertion Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Executing Automated Synthetic Monitoring Test Suite...${CLR_RESET}"
./test_synthetic_monitoring.sh

echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All Synthetic Journey Monitoring Benchmarks & Tests Passed!${CLR_RESET}"
echo -e "🔗 CloudStore Target App:  ${CLR_CYAN}http://localhost:8080${CLR_RESET}"
echo -e "🔗 Playwright Exporter:    ${CLR_CYAN}http://localhost:9115/metrics${CLR_RESET}"
echo -e "🔗 Prometheus Web Console: ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
echo -e "🔗 Grafana Dashboard:      ${CLR_CYAN}http://localhost:3000/d/synthetic-user-journeys${CLR_RESET} (Login: ${CLR_BOLD}admin${CLR_RESET} / ${CLR_BOLD}admin${CLR_RESET})"
echo -e "\nTo clean up all containers, images, and screenshots, run:"
echo -e "  ${CLR_BOLD}./cleanup.sh --purge-images${CLR_RESET}\n"
