#!/usr/bin/env bash
# ==============================================================================
# simulate_pagerduty_alert.sh - Synthetic Alert Generator & HMAC Signer
# ==============================================================================
# Generates synthetic PagerDuty v3 / Alertmanager / Generic alert payloads,
# signs them with HMAC-SHA256, and dispatches them to the Runbook Executor.
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

EXECUTOR_URL="${EXECUTOR_URL:-http://localhost:8080}"
SECRET="${WEBHOOK_SECRET:-sre-remediation-secret-token-12345}"
INCIDENT_TYPE="worker-hung"
FORMAT="pagerduty"
INVALID_SIG=false

for arg in "$@"; do
    case "$arg" in
        --incident-type=*)
            INCIDENT_TYPE="${arg#*=}"
            ;;
        --format=*)
            FORMAT="${arg#*=}"
            ;;
        --invalid-sig|--tamper)
            INVALID_SIG=true
            ;;
        --url=*)
            EXECUTOR_URL="${arg#*=}"
            ;;
        --secret=*)
            SECRET="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./simulate_pagerduty_alert.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --incident-type=<worker-hung|cache-oom|queue-backlog|dlq-spike> (default: worker-hung)"
            echo "  --format=<pagerduty|alertmanager|generic>                       (default: pagerduty)"
            echo "  --invalid-sig                                                  (Send tampered signature to test rejection)"
            echo "  --url=<url>                                                    (Executor URL, default: http://localhost:8080)"
            echo "  --secret=<secret>                                              (HMAC shared secret)"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run ./simulate_pagerduty_alert.sh --help for options."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🚨 SIMULATING SRE INCIDENT ALERT PAYLOAD"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo "  Incident Type: $INCIDENT_TYPE"
echo "  Format:        $FORMAT"
echo "  Target URL:    $EXECUTOR_URL"

# 1. Build Payload based on incident type and format
INCIDENT_ID="inc-$(date +%s)"
ALERT_NAME=""
SERVICE_NAME=""
SUMMARY=""

case "$INCIDENT_TYPE" in
    worker-hung|worker_hung|worker)
        ALERT_NAME="HungWorkerDetected"
        SERVICE_NAME="worker-service"
        SUMMARY="Critical: worker pool thread deadlock detected (100% CPU lock)"
        ;;
    cache-oom|cache_oom|cache)
        ALERT_NAME="RedisMemoryCritical"
        SERVICE_NAME="redis-cache"
        SUMMARY="High: Redis memory utilization reached 96.5% of maxmemory limit"
        ;;
    queue-backlog|queue_backlog|queue)
        ALERT_NAME="QueueBacklogHigh"
        SERVICE_NAME="order-queue"
        SUMMARY="Warning: Order processing backlog surged to 48,500 messages"
        ;;
    dlq-spike|dlq_spike|dlq)
        ALERT_NAME="DeadLetterQueueSpike"
        SERVICE_NAME="order-queue"
        SUMMARY="Warning: Dead-letter queue contains 1,240 failed unprocessable messages"
        ;;
    *)
        ALERT_NAME="GenericAlert"
        SERVICE_NAME="unknown-service"
        SUMMARY="Generic incident trigger"
        ;;
esac

ENDPOINT=""
PAYLOAD=""

if [ "$FORMAT" = "pagerduty" ]; then
    ENDPOINT="$EXECUTOR_URL/webhook/pagerduty"
    PAYLOAD=$(cat <<EOF
{
  "event": {
    "id": "ev-${INCIDENT_ID}",
    "event_type": "incident.triggered",
    "resource_type": "incident",
    "occurred_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "data": {
      "id": "${INCIDENT_ID}",
      "type": "incident",
      "title": "${ALERT_NAME}",
      "status": "triggered",
      "urgency": "high",
      "service": {
        "id": "PABC123",
        "summary": "${SERVICE_NAME}"
      },
      "custom_details": {
        "alertname": "${ALERT_NAME}",
        "service": "${SERVICE_NAME}",
        "summary": "${SUMMARY}"
      }
    }
  }
}
EOF
)
elif [ "$FORMAT" = "alertmanager" ]; then
    ENDPOINT="$EXECUTOR_URL/webhook/alertmanager"
    PAYLOAD=$(cat <<EOF
{
  "receiver": "on-call-pager-receiver",
  "status": "firing",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "${ALERT_NAME}",
        "service": "${SERVICE_NAME}",
        "severity": "critical"
      },
      "annotations": {
        "summary": "${SUMMARY}"
      },
      "startsAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
  ]
}
EOF
)
else
    ENDPOINT="$EXECUTOR_URL/webhook/generic"
    PAYLOAD=$(cat <<EOF
{
  "incident_id": "${INCIDENT_ID}",
  "alertname": "${ALERT_NAME}",
  "service": "${SERVICE_NAME}",
  "event_type": "trigger",
  "summary": "${SUMMARY}"
}
EOF
)
fi

# 2. Compute HMAC-SHA256 Signature
if [ "$INVALID_SIG" = true ]; then
    SIGNATURE="v1=0000000000000000000000000000000000000000000000000000000000000000"
    echo -e "  Signature:     ${CLR_RED}$SIGNATURE (Tampered / Invalid)${CLR_RESET}"
else
    HEX_SIG=$(printf "%s" "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')
    SIGNATURE="v1=$HEX_SIG"
    echo -e "  Signature:     ${CLR_GREEN}$SIGNATURE (Valid HMAC-SHA256)${CLR_RESET}"
fi

echo -e "\n${CLR_YELLOW}▶ Dispatching signed HTTP POST request to $ENDPOINT...${CLR_RESET}"

HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/runbook_resp.json \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "X-Webhook-Signature: $SIGNATURE" \
    -H "X-PagerDuty-Signature: $SIGNATURE" \
    -d "$PAYLOAD")

echo -e "\n${CLR_BOLD}Response Status:${CLR_RESET} HTTP $HTTP_CODE"
if [ -f /tmp/runbook_resp.json ]; then
    echo -e "${CLR_BOLD}Response Payload:${CLR_RESET}"
    cat /tmp/runbook_resp.json | python3 -m json.tool 2>/dev/null || cat /tmp/runbook_resp.json
    rm -f /tmp/runbook_resp.json
fi
echo ""
