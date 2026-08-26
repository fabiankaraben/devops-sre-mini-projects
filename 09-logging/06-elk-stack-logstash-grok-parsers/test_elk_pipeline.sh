#!/usr/bin/env bash
# ==============================================================================
# test_elk_pipeline.sh - Automated End-to-End Test Suite for ELK Stack
# ==============================================================================
# 1. Checks prerequisites (Docker, Docker Compose, Python 3).
# 2. Launches the ELK stack (Elasticsearch, Logstash, Kibana).
# 3. Awaits cluster readiness and pipeline initialization.
# 4. Streams raw unstructured access logs via log_injector.py.
# 5. Executes verify_pipeline.py to assert Grok parsing and GeoIP enrichment.
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
echo "  🚀 ELK Stack with Logstash Grok Parsers - Automated Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. System Prerequisites Check
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking System Prerequisites...${CLR_RESET}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker daemon is not running. Please start OrbStack or Docker Desktop."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker engine is running."

COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Docker Compose CLI not found."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Docker Compose: ${CLR_BOLD}${COMPOSE_CMD}${CLR_RESET}"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Python 3 is required for log injection and verification."
    exit 1
fi
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Python runtime: $(python3 --version)"

# ------------------------------------------------------------------------------
# 2. Start the ELK Docker Stack
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Building & Starting Elasticsearch, Logstash, and Kibana Stack...${CLR_RESET}"

$COMPOSE_CMD build
$COMPOSE_CMD up -d --remove-orphans

echo "  Waiting for Elasticsearch (:9200), Logstash (:9600), and Kibana (:5601) to become healthy..."
MAX_WAIT=120
RETRY=0
ES_READY=false
LS_READY=false
KIBANA_READY=false

while [ $RETRY -lt $MAX_WAIT ]; do
    if [ "$ES_READY" = false ]; then
        if curl -s -f "http://127.0.0.1:9200/_cluster/health" 2>/dev/null | grep -Eq '"status":"(green|yellow)"'; then
            ES_READY=true
            echo -e "  [${CLR_GREEN}READY${CLR_RESET}] Elasticsearch is healthy."
        fi
    fi

    if [ "$LS_READY" = false ]; then
        if docker logs elk-stack-logstash 2>&1 | grep -q 'Pipeline started {"pipeline.id"=>"elk-grok-pipeline"}'; then
            LS_READY=true
            echo -e "  [${CLR_GREEN}READY${CLR_RESET}] Logstash pipeline engine is operational and listeners are active."
        fi
    fi

    if [ "$KIBANA_READY" = false ]; then
        if curl -s -f "http://127.0.0.1:5601/api/status" 2>/dev/null | grep -q '"level":"available"'; then
            KIBANA_READY=true
            echo -e "  [${CLR_GREEN}READY${CLR_RESET}] Kibana web UI is available."
        fi
    fi

    if [ "$ES_READY" = true ] && [ "$LS_READY" = true ] && [ "$KIBANA_READY" = true ]; then
        break
    fi

    sleep 3
    RETRY=$((RETRY + 3))
    echo -e "  ${CLR_GRAY}Still initializing services (${RETRY}s/${MAX_WAIT}s)...${CLR_RESET}"
done

if [ "$ES_READY" = false ] || [ "$LS_READY" = false ] || [ "$KIBANA_READY" = false ]; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Services failed to become ready within timeout period."
    $COMPOSE_CMD ps
    exit 1
fi

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Full ELK Stack is healthy and accepting traffic."

# ------------------------------------------------------------------------------
# 3. Stream Synthetic & Fixture Logs to Logstash
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Streaming Access Logs to Logstash via TCP (:50000)...${CLR_RESET}"

# Give Logstash TCP listener an extra 2 seconds to bind
sleep 2

# Inject diverse synthetic log stream
python3 log_injector.py --host 127.0.0.1 --tcp-port 50000 --count 100 --rate 50

# Inject curated fixture test logs
echo -e "\n  Streaming test fixture files..."
python3 log_injector.py --sample-file sample_logs/raw_apache_access.log --tcp-port 50000
python3 log_injector.py --sample-file sample_logs/raw_nginx_access.log --tcp-port 50000
python3 log_injector.py --sample-file sample_logs/raw_app_errors.log --tcp-port 50000
python3 log_injector.py --sample-file sample_logs/malformed_logs.log --tcp-port 50000

# Also test HTTP ingestion path
echo -e "\n  Streaming via HTTP REST input (:8080)..."
python3 log_injector.py --protocol http --http-port 8080 --count 10

# ------------------------------------------------------------------------------
# 4. Refresh Elasticsearch Index
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Synchronizing & Refreshing Elasticsearch Indices...${CLR_RESET}"
sleep 3
curl -s -X POST "http://127.0.0.1:9200/elk-logs-*/_refresh" >/dev/null || true
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Index refresh complete."

# ------------------------------------------------------------------------------
# 5. Run Verification Assertions
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Running Automated Pipeline Verification Suite...${CLR_RESET}"
python3 verify_pipeline.py

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ ELK Stack with Logstash Grok Parsers testing completed successfully!${CLR_RESET}"
echo -e "You can now open Kibana in your browser: ${CLR_CYAN}${CLR_BOLD}http://localhost:5601${CLR_RESET}"
