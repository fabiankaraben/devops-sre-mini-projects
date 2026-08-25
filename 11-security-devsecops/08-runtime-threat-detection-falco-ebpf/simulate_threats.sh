#!/usr/bin/env bash
# ==============================================================================
# simulate_threats.sh - Automated Container Runtime Threat & Exploit Simulator
# ==============================================================================
# Triggers 5 realistic security anomalies inside the target victim container
# to evaluate Falco eBPF detection fidelity in real time:
#   1. Interactive shell spawn in container (MITRE T1059)
#   2. Sensitive credential file read /etc/shadow (MITRE T1003)
#   3. Outbound reverse shell connection to port 4444 (MITRE T1571)
#   4. Process dropped and executed from /tmp (MITRE T1027)
#   5. Tampering with system binary directory /usr/bin (MITRE T1543)
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_TARGET="victim-payment-app"
DELAY_BETWEEN_THREATS=2

print_usage() {
    echo -e "${CLR_CYAN}Usage: ./simulate_threats.sh [OPTIONS]${CLR_RESET}"
    echo ""
    echo "Options:"
    echo "  --container <NAME>     Target container name (default: victim-payment-app)"
    echo "  --delay <SECONDS>      Delay between threat simulations (default: 2)"
    echo "  --help, -h             Show this help message"
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)
            CONTAINER_TARGET="$2"
            shift 2
            ;;
        --delay)
            DELAY_BETWEEN_THREATS="$2"
            shift 2
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Error: Unknown argument '$1'${CLR_RESET}"
            print_usage
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  💥 CONTAINER RUNTIME THREAT & EXPLOIT SIMULATOR"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e " Target Container : ${CLR_BOLD}${CONTAINER_TARGET}${CLR_RESET}"
echo -e " Delay Interval   : ${CLR_GRAY}${DELAY_BETWEEN_THREATS}s${CLR_RESET}"
echo "======================================================================"

# Verify container exists and is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_TARGET}$"; then
    echo -e "${CLR_RED}Error: Target container '${CONTAINER_TARGET}' is not running.${CLR_RESET}"
    echo "Please start the sandbox first with: docker compose up -d"
    exit 1
fi

# ------------------------------------------------------------------------------
# THREAT 1: Interactive Terminal Shell Spawned in Container
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Threat 1/5] Simulating Interactive Shell Spawn inside Container...${CLR_RESET}"
echo -e "  [${CLR_GRAY}ACTION${CLR_RESET}] Executing /bin/bash via docker exec..."
docker exec "$CONTAINER_TARGET" /bin/bash -c "echo 'ATTACKER_SESSION_INITIATED: whoami=' && whoami" >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}TRIGGERED${CLR_RESET}] Shell spawned (Rule: 'Terminal Shell Spawned in Container')"
sleep "$DELAY_BETWEEN_THREATS"

# ------------------------------------------------------------------------------
# THREAT 2: Sensitive Credential File Read (/etc/shadow)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Threat 2/5] Simulating Unauthorized Read on /etc/shadow...${CLR_RESET}"
echo -e "  [${CLR_GRAY}ACTION${CLR_RESET}] Attempting cat /etc/shadow..."
docker exec "$CONTAINER_TARGET" cat /etc/shadow >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}TRIGGERED${CLR_RESET}] Credential read executed (Rule: 'Read Sensitive Credential File')"
sleep "$DELAY_BETWEEN_THREATS"

# ------------------------------------------------------------------------------
# THREAT 3: Outbound Reverse Shell Connection
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Threat 3/5] Simulating Outbound Reverse Shell to Port 4444...${CLR_RESET}"
echo -e "  [${CLR_GRAY}ACTION${CLR_RESET}] Initiating connection via netcat to 127.0.0.1:4444..."
docker exec "$CONTAINER_TARGET" sh -c "nc -w 1 127.0.0.1 4444 2>/dev/null || true" >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}TRIGGERED${CLR_RESET}] Reverse shell connection attempted (Rule: 'Outbound Reverse Shell Connection')"
sleep "$DELAY_BETWEEN_THREATS"

# ------------------------------------------------------------------------------
# THREAT 4: Process Dropped and Executed from /tmp
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Threat 4/5] Simulating Malicious Binary Execution from /tmp...${CLR_RESET}"
echo -e "  [${CLR_GRAY}ACTION${CLR_RESET}] Dropping and executing payload at /tmp/malicious_payload.sh..."
docker exec -w /tmp "$CONTAINER_TARGET" sh -c "echo '#!/bin/sh' > /tmp/malicious_payload.sh && echo 'echo EXPLOIT_RUNNING' >> /tmp/malicious_payload.sh && chmod +x /tmp/malicious_payload.sh && /tmp/malicious_payload.sh && rm -f /tmp/malicious_payload.sh" >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}TRIGGERED${CLR_RESET}] Binary launched from /tmp (Rule: 'Execution from Writable Directory /tmp')"
sleep "$DELAY_BETWEEN_THREATS"

# ------------------------------------------------------------------------------
# THREAT 5: Tampering with System Binary Directory /usr/bin
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Threat 5/5] Simulating Tampering with /usr/bin/tamper_probe...${CLR_RESET}"
echo -e "  [${CLR_GRAY}ACTION${CLR_RESET}] Writing modification probe to /usr/bin..."
docker exec "$CONTAINER_TARGET" sh -c "touch /usr/bin/tamper_probe && rm -f /usr/bin/tamper_probe" >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}TRIGGERED${CLR_RESET}] File modification probe written (Rule: 'System Binary Directory Modification')"

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================"
echo "  ✅ ALL 5 THREAT VECTORS SIMULATED SUCCESSFULLY"
echo "======================================================================${CLR_RESET}"
echo -e " Verify Falco alerts with: ${CLR_CYAN}python3 alert_verifier.py --audit${CLR_RESET}"
echo "======================================================================"
