#!/usr/bin/env bash
# ==============================================================================
# trigger_synthetic_alert.sh - Synthetic Incident & Failure Generator
# ==============================================================================
# Simulates realistic production incidents to trigger Prometheus alerting rules
# and verify Alertmanager routing, grouping, inhibition, and webhook notifications:
#   1. errors   - Injects 5xx server errors -> Triggers HighHttpErrorRate (Critical)
#   2. latency  - Injects high response delay -> Triggers SlowResponseTime (Warning)
#   3. crash    - Triggers ServiceDown (Critical) & Tests Inhibition of child alerts
#   4. recover  - Restores service to healthy state -> Auto-resolves firing alerts
#   5. status   - Inspects live alert states across Prometheus & Alertmanager
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
CLR_WHITE="\033[1;37m"

APP_URL="${APP_URL:-http://localhost:8000}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
AM_URL="${AM_URL:-http://localhost:9093}"
WEBHOOK_URL="${WEBHOOK_URL:-http://localhost:5001}"

show_help() {
    cat <<EOF
Usage: ./trigger_synthetic_alert.sh [OPTIONS]

Options:
  --scenario, -s SCENARIO   Incident scenario to trigger:
                            • errors   : HTTP 5xx error burst (Critical -> #slack-critical)
                            • latency  : Response delay spike (Warning -> #slack-warnings)
                            • crash    : Total service outage (Critical -> Inhibits child alerts)
                            • recover  : Recover service from crash and resolve alerts
                            • status   : Query active alert states and delivered notifications
  --duration, -d SECONDS    Duration in seconds to send traffic (default: 12)
  --help, -h                Show this help menu

Examples:
  ./trigger_synthetic_alert.sh --scenario errors
  ./trigger_synthetic_alert.sh --scenario crash
  ./trigger_synthetic_alert.sh --scenario recover
  ./trigger_synthetic_alert.sh --scenario status
EOF
    exit 0
}

SCENARIO="status"
DURATION=12

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario|-s)
            SCENARIO="$2"
            shift 2
            ;;
        --duration|-d)
            DURATION="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Unknown argument: $1"
            show_help
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚨 Prometheus Alertmanager Incident & Notification Trigger"
echo "======================================================================"
echo -e "${CLR_RESET}"

case "$SCENARIO" in
    # --------------------------------------------------------------------------
    # Scenario 1: HTTP 5xx Error Burst
    # --------------------------------------------------------------------------
    errors|high-errors)
        echo -e "${CLR_YELLOW}▶ Triggering Incident: High HTTP 5xx Error Rate...${CLR_RESET}"
        echo -e "  Target: ${CLR_WHITE}${APP_URL}/api/flaky${CLR_RESET} (Duration: ${DURATION}s)"
        echo -e "  Expected Alert : ${CLR_RED}HighHttpErrorRate (Severity: critical)${CLR_RESET}"
        echo -e "  Expected Route : ${CLR_CYAN}#slack-critical${CLR_RESET}\n"

        END_TIME=$((SECONDS + DURATION))
        SENT=0
        while [ $SECONDS -lt $END_TIME ]; do
            curl -s "${APP_URL}/api/flaky?error_rate=0.9" >/dev/null 2>&1 || true
            SENT=$((SENT + 1))
            sys_time=$((END_TIME - SECONDS))
            echo -ne "  [Running] Sent ${SENT} failing requests... (${sys_time}s remaining)\r"
            sleep 0.2
        done
        echo -e "\n  [${CLR_GREEN}DONE${CLR_RESET}] Sent ${SENT} requests with ~90% error rate."
        echo -e "  Prometheus will transition HighHttpErrorRate to ${CLR_RED}FIRING${CLR_RESET}."
        ;;

    # --------------------------------------------------------------------------
    # Scenario 2: Slow Latency Spike
    # --------------------------------------------------------------------------
    latency|slow-latency)
        echo -e "${CLR_YELLOW}▶ Triggering Incident: Elevated p95 Latency Spike...${CLR_RESET}"
        echo -e "  Target: ${CLR_WHITE}${APP_URL}/api/slow${CLR_RESET} (Duration: ${DURATION}s)"
        echo -e "  Expected Alert : ${CLR_YELLOW}SlowResponseTime (Severity: warning)${CLR_RESET}"
        echo -e "  Expected Route : ${CLR_CYAN}#slack-warnings${CLR_RESET}\n"

        END_TIME=$((SECONDS + DURATION))
        SENT=0
        while [ $SECONDS -lt $END_TIME ]; do
            curl -s "${APP_URL}/api/slow?delay=0.8" >/dev/null 2>&1 || true
            SENT=$((SENT + 1))
            sys_time=$((END_TIME - SECONDS))
            echo -ne "  [Running] Sent ${SENT} slow requests (>800ms)... (${sys_time}s remaining)\r"
            sleep 0.3
        done
        echo -e "\n  [${CLR_GREEN}DONE${CLR_RESET}] Sent ${SENT} slow transactions."
        echo -e "  Prometheus will transition SlowResponseTime to ${CLR_YELLOW}FIRING${CLR_RESET}."
        ;;

    # --------------------------------------------------------------------------
    # Scenario 3: Complete Service Outage (Inhibition Test)
    # --------------------------------------------------------------------------
    crash|service-outage)
        echo -e "${CLR_YELLOW}▶ Triggering Incident: Service Outage & Cascading Inhibition...${CLR_RESET}"
        echo -e "  Target: ${CLR_WHITE}${APP_URL}/api/crash${CLR_RESET}"
        echo -e "  Expected Alert : ${CLR_RED}ServiceDown (Severity: critical)${CLR_RESET}"
        echo -e "  Inhibition Test: Suppresses dependent warnings (SlowResponseTime)\n"

        RESP="$(curl -s "${APP_URL}/api/crash" || echo '{}')"
        echo -e "  Response: ${CLR_WHITE}${RESP}${CLR_RESET}"
        echo -e "  Target endpoint is now failing health checks."
        echo -e "  In ~10 seconds, Prometheus will fire ${CLR_RED}ServiceDown${CLR_RESET} and Alertmanager will inhibit child alerts."
        ;;

    # --------------------------------------------------------------------------
    # Scenario 4: Service Recovery (Auto-Resolve Test)
    # --------------------------------------------------------------------------
    recover|restore)
        echo -e "${CLR_YELLOW}▶ Restoring Service Health & Triggering Auto-Resolution...${CLR_RESET}"
        echo -e "  Target: ${CLR_WHITE}${APP_URL}/api/recover${CLR_RESET}\n"

        RESP="$(curl -s "${APP_URL}/api/recover" || echo '{}')"
        echo -e "  Response: ${CLR_WHITE}${RESP}${CLR_RESET}"

        # Send steady normal traffic to clear counters
        echo "  Sending healthy steady traffic to clear error rates..."
        for _ in {1..15}; do
            curl -s "${APP_URL}/api/items" >/dev/null 2>&1 || true
            sleep 0.2
        done
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Normal traffic restored. Prometheus will send ${CLR_GREEN}RESOLVED${CLR_RESET} notifications."
        ;;

    # --------------------------------------------------------------------------
    # Scenario 5: Query Live Alert Status
    # --------------------------------------------------------------------------
    status)
        echo -e "${CLR_YELLOW}▶ Inspecting Active Alert Pipeline States...${CLR_RESET}\n"

        # Prometheus Alerts
        echo -e "  ${CLR_BOLD}[1] Prometheus Active Alerts (${PROM_URL}/api/v1/alerts):${CLR_RESET}"
        PROM_ALERTS="$(curl -s "${PROM_URL}/api/v1/alerts" || echo '{}')"
        echo "$PROM_ALERTS" | python3 -c "
import sys, json
try:
    alerts = json.load(sys.stdin).get('data', {}).get('alerts', [])
    if not alerts:
        print('      (No alerts currently active in Prometheus)')
    for a in alerts:
        name = a.get('labels', {}).get('alertname', 'Unknown')
        state = a.get('state', 'unknown').upper()
        sev = a.get('labels', {}).get('severity', 'info')
        val = a.get('value', '')
        print(f'      • {name:<22} State: {state:<9} Severity: {sev:<10} Value: {val}')
except Exception as e:
    print('      Error parsing Prometheus alerts: ' + str(e))
"

        # Alertmanager Active Alerts
        echo -e "\n  ${CLR_BOLD}[2] Alertmanager Ingested Alerts (${AM_URL}/api/v2/alerts):${CLR_RESET}"
        AM_ALERTS="$(curl -s "${AM_URL}/api/v2/alerts" || echo '[]')"
        echo "$AM_ALERTS" | python3 -c "
import sys, json
try:
    alerts = json.load(sys.stdin)
    if not alerts:
        print('      (No alerts in Alertmanager queue)')
    for a in alerts:
        name = a.get('labels', {}).get('alertname', 'Unknown')
        state = a.get('status', {}).get('state', 'active')
        sev = a.get('labels', {}).get('severity', 'info')
        inhibited = a.get('status', {}).get('inhibitedBy', [])
        inhibit_str = f' (Inhibited by: {inhibited})' if inhibited else ''
        print(f'      • {name:<22} Status: {state:<8} Severity: {sev:<10}{inhibit_str}')
except Exception as e:
    print('      Error parsing Alertmanager alerts: ' + str(e))
"

        # Webhook / Slack Delivery History
        echo -e "\n  ${CLR_BOLD}[3] Mock Slack Sandbox Received Webhooks (${WEBHOOK_URL}/api/alerts/received):${CLR_RESET}"
        WH_DATA="$(curl -s "${WEBHOOK_URL}/api/alerts/received" || echo '{}')"
        echo "$WH_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    count = data.get('count', 0)
    alerts = data.get('alerts', [])
    print(f'      Total Webhook Notifications Delivered: {count}')
    for idx, a in enumerate(alerts[-5:], 1):
        ch = a.get('channel', 'default')
        status = a.get('status', '').upper()
        name = a.get('alertname', '')
        sev = a.get('severity', '')
        print(f'      [{idx}] #{ch:<16} Status: {status:<8} Alert: {name:<20} Severity: {sev}')
except Exception as e:
    print('      Error querying Webhook receiver: ' + str(e))
"
        ;;

    *)
        echo -e "${CLR_RED}Unknown scenario: ${SCENARIO}${CLR_RESET}"
        show_help
        ;;
esac

echo ""
