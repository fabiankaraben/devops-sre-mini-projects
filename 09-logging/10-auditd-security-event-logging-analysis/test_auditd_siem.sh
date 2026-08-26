#!/usr/bin/env bash
# ==============================================================================
# Auditd Linux Security Event Log Analysis - Automated Test Suite
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
echo -e "${CLR_CYAN}${CLR_BOLD}  🛡️  Linux Auditd & SIEM Security Analysis - Test Runner${CLR_RESET}"
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
# 2. Build & Start SIEM Dashboard and Audit Shipper
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building & Launching SIEM Security Stack...${CLR_RESET}"

$COMPOSE_CMD build
$COMPOSE_CMD up -d --remove-orphans

echo -e "  Waiting for SIEM Server (:9099) and Audit Shipper..."

MAX_WAIT=30
RETRY=0
READY=false

while [ $RETRY -lt $MAX_WAIT ]; do
    if curl -s -f -o /dev/null "http://127.0.0.1:9099/api/health" 2>/dev/null; then
        READY=true
        echo -e "  [${CLR_GREEN}READY${CLR_RESET}] SIEM Security Dashboard & API is operational."
        break
    fi
    sleep 1
    RETRY=$((RETRY + 1))
done

if [ "$READY" = false ]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] SIEM Server failed to become healthy in ${MAX_WAIT}s."
    $COMPOSE_CMD ps
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Simulate Security Attacks & File Modifications
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Simulating Critical Security Incidents & FIM Attacks...${CLR_RESET}"
./simulate_security_event.sh

# ------------------------------------------------------------------------------
# 4. Wait for Correlation & SIEM Ingestion
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [4/5] Allowing Audit Shipper to correlate multi-line events (3s)...${CLR_RESET}"
sleep 3

# ------------------------------------------------------------------------------
# 5. Run Verification Suite
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [5/5] Executing SIEM Security Verification Suite...${CLR_RESET}"
python3 verify_audit_siem.py

echo -e "\n${CLR_YELLOW}▶ Visual Web UI Available:${CLR_RESET}"
echo -e "  ${CLR_CYAN}👉 SIEM SOC Security Threat Dashboard:${CLR_RESET} http://localhost:9099\n"

echo -e "${CLR_GREEN}${CLR_BOLD}✨ Linux Auditd Security Event Log Analysis tests completed successfully!${CLR_RESET}\n"
