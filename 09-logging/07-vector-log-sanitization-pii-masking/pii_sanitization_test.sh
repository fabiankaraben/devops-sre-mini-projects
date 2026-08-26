#!/usr/bin/env bash
# ==============================================================================
# Vector Log Sanitization and PII Masking - Automated Test Runner
# ==============================================================================
set -e

# Color definitions for output
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
echo -e "${CLR_CYAN}${CLR_BOLD}  🛡️  Vector Log Sanitization & PII Masking - Test Suite${CLR_RESET}"
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
# 2. Build & Launch Vector Container
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building & Launching Vector Pipeline Container...${CLR_RESET}"

$COMPOSE_CMD build
$COMPOSE_CMD up -d --remove-orphans

echo -e "  Waiting for Vector API (:8686), HTTP (:8080), and TCP (:9000) to initialize..."

MAX_WAIT=30
RETRY=0
VECTOR_READY=false

while [ $RETRY -lt $MAX_WAIT ]; do
    if curl -s -f "http://127.0.0.1:8686/health" 2>/dev/null | grep -q "ok"; then
        VECTOR_READY=true
        echo -e "  [${CLR_GREEN}READY${CLR_RESET}] Vector API and transforms are operational."
        break
    fi
    sleep 1
    RETRY=$((RETRY + 1))
    echo -e "  ${CLR_GRAY}Waiting for Vector (${RETRY}s/${MAX_WAIT}s)...${CLR_RESET}"
done

if [ "$VECTOR_READY" = false ]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Vector failed to start within ${MAX_WAIT}s."
    $COMPOSE_CMD logs
    exit 1
fi

# Ensure output log file exists inside container
docker exec vector-sanitizer touch /var/log/vector/sanitized.log

# ------------------------------------------------------------------------------
# 3. Stream Synthetic & Fixture PII Logs
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Forwarding PII Telemetry to Vector Pipeline...${CLR_RESET}"

echo -e "  ${CLR_CYAN}Streaming Synthetic PII batch (Credit Cards, SSNs, Passwords, JWTs)...${CLR_RESET}"
python3 pii_log_generator.py --protocol http --http-port 8080 --count 100 --rate 50

echo -e "  ${CLR_CYAN}Streaming Raw Credit Card Fixtures via TCP Socket (:9000)...${CLR_RESET}"
python3 pii_log_generator.py --protocol tcp --tcp-port 9000 --sample-file sample_logs/raw_credit_card_logs.log

echo -e "  ${CLR_CYAN}Streaming Raw SSN & Identity Fixtures via HTTP (:8080)...${CLR_RESET}"
python3 pii_log_generator.py --protocol http --http-port 8080 --sample-file sample_logs/raw_ssn_identity_logs.log

echo -e "  ${CLR_CYAN}Streaming Raw Auth Secrets & Bearer JWT Fixtures via TCP (:9000)...${CLR_RESET}"
python3 pii_log_generator.py --protocol tcp --tcp-port 9000 --sample-file sample_logs/raw_auth_secrets_logs.log

echo -e "  ${CLR_CYAN}Streaming Unstructured Text Fixtures via HTTP (:8080)...${CLR_RESET}"
python3 pii_log_generator.py --protocol http --http-port 8080 --sample-file sample_logs/raw_unstructured_mixed.log

# Brief yield for Vector buffer flush
sleep 2

# ------------------------------------------------------------------------------
# 4. Preview Sanitized Logs from Output Sink
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Inspecting Vector Sanitized Output Sink (/var/log/vector/sanitized.log)...${CLR_RESET}"
echo -e "${CLR_GRAY}--- Last 3 Sanitized Records ---${CLR_RESET}"
docker exec vector-sanitizer tail -n 3 /var/log/vector/sanitized.log || true

# ------------------------------------------------------------------------------
# 5. Execute Automated Zero-Leakage Audit Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Running Zero-Leakage Security Verification Suite...${CLR_RESET}"
python3 verify_pii_sanitization.py

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Vector Log Sanitization and PII Masking test suite completed successfully!${CLR_RESET}\n"
