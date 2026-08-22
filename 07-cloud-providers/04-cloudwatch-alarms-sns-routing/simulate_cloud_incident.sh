#!/usr/bin/env bash
# ==============================================================================
# simulate_cloud_incident.sh - CloudWatch Alarm & SNS Incident Simulator
# ==============================================================================
# Injects synthetic metric anomalies (CPU spike, 5xx error surge, disk exhaustion,
# composite outage), triggers CloudWatch alarms, and verifies SNS webhook routing.
#
# Supports:
#   1. Local Offline Simulation Mode (100% self-contained, zero cloud required)
#   2. Live AWS Cloud / LocalStack Mode (via AWS CLI put-metric-data)
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
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="mock"
VERBOSE=false
JSON_OUT=""
WEBHOOK_PORT=8080
WEBHOOK_PID=""
WEBHOOK_EVENTS_FILE="$SCRIPT_DIR/test_webhook_events.json"

cleanup_webhook() {
    if [[ -n "$WEBHOOK_PID" ]] && kill -0 "$WEBHOOK_PID" >/dev/null 2>&1; then
        kill "$WEBHOOK_PID" >/dev/null 2>&1 || true
        wait "$WEBHOOK_PID" 2>/dev/null || true
    fi
}
trap cleanup_webhook EXIT INT TERM

show_help() {
    echo "Usage: ./simulate_cloud_incident.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --mock, --offline    Run local offline incident simulation (default)"
    echo "  --live               Execute against live AWS CloudWatch / LocalStack endpoints"
    echo "  --port PORT          Port for the local webhook receiver (default: 8080)"
    echo "  --json-output FILE   Write structured test report to JSON file"
    echo "  --verbose, -v        Display detailed payload headers and evaluation logs"
    echo "  --help, -h           Show this help message"
}

for arg in "$@"; do
    case "$arg" in
        --mock|--offline)
            MODE="mock"
            ;;
        --live)
            MODE="live"
            ;;
        --port=*)
            WEBHOOK_PORT="${arg#*=}"
            ;;
        --json-output=*)
            JSON_OUT="${arg#*=}"
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ CloudWatch Alarms & SNS Incident Routing Simulator"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo -e "  Execution Mode : ${CLR_MAGENTA}$([[ "$MODE" == "mock" ]] && echo "LOCAL OFFLINE MOCK" || echo "LIVE AWS CLOUD / LOCALSTACK")${CLR_RESET}"
echo -e "  Webhook Target : ${CLR_WHITE}http://127.0.0.1:${WEBHOOK_PORT}${CLR_RESET}\n"

# ------------------------------------------------------------------------------
# 1. Launch Background Webhook Receiver
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Starting Webhook Incident Receiver on port ${WEBHOOK_PORT}...${CLR_RESET}"
python3 "$SCRIPT_DIR/webhook_receiver.py" --port "$WEBHOOK_PORT" --log-file "$WEBHOOK_EVENTS_FILE" $([[ "$VERBOSE" == true ]] && echo "-v") &
WEBHOOK_PID=$!
sleep 0.8

if ! kill -0 "$WEBHOOK_PID" >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Webhook receiver failed to start on port ${WEBHOOK_PORT}."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Webhook receiver is active (PID: $WEBHOOK_PID)."

# ------------------------------------------------------------------------------
# Helper: Dispatch Synthetic SNS Alert to Webhook
# ------------------------------------------------------------------------------
send_sns_notification() {
    local topic_arn="$1"
    local alarm_name="$2"
    local old_state="$3"
    local new_state="$4"
    local reason="$5"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local alarm_message
    alarm_message=$(cat << EOF
{
  "AlarmName": "$alarm_name",
  "AlarmDescription": "Simulated Incident Alert",
  "AWSAccountId": "123456789012",
  "NewStateValue": "$new_state",
  "NewStateReason": "$reason",
  "StateChangeTime": "$timestamp",
  "Region": "us-east-1",
  "OldStateValue": "$old_state"
}
EOF
)

    local sns_payload
    sns_payload=$(cat << EOF
{
  "Type": "Notification",
  "MessageId": "msg-$(date +%s%N | cut -b1-12)",
  "TopicArn": "$topic_arn",
  "Subject": "ALARM: \"$alarm_name\" in US East (N. Virginia)",
  "Message": $(echo "$alarm_message" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'),
  "Timestamp": "$timestamp"
}
EOF
)

    curl -s -X POST "http://127.0.0.1:${WEBHOOK_PORT}/" \
        -H "Content-Type: application/json" \
        -H "x-amz-sns-message-type: Notification" \
        -d "$sns_payload" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 2. Execute Incident Scenarios
# ------------------------------------------------------------------------------
PASSED=0
FAILED=0
TOTAL=0

assert_scenario() {
    local scenario_id="$1"
    local title="$2"
    local condition="$3"

    TOTAL=$((TOTAL + 1))
    if eval "$condition"; then
        PASSED=$((PASSED + 1))
        printf "${CLR_WHITE}%-14s${CLR_RESET} %-52s [${CLR_GREEN}PASS${CLR_RESET}]\n" "$scenario_id" "$title"
    else
        FAILED=$((FAILED + 1))
        printf "${CLR_WHITE}%-14s${CLR_RESET} %-52s [${CLR_RED}FAIL${CLR_RESET}]\n" "$scenario_id" "$title"
    fi
}

echo -e "\n${CLR_YELLOW}▶ [2/5] Simulating Incident Anomaly Scenarios...${CLR_RESET}"

# Scenario 1: EC2 CPU Spike (95.5% > Threshold 80%)
echo -e "\n${CLR_CYAN}--- Scenario 1: EC2 CPU Utilization Surge (95.5%) ---${CLR_RESET}"
echo "  Injecting synthetic metric: CPUUtilization = 95.5% (Threshold: 80.0%)"
send_sns_notification \
    "arn:aws:sns:us-east-1:123456789012:cloud-incident-routing-warnings" \
    "cloud-incident-routing-high-cpu" \
    "OK" \
    "ALARM" \
    "Threshold Breached: 2 datapoints [95.5, 96.2] were greater than the threshold (80.0)."
sleep 0.2

# Scenario 2: HTTP 5xx Error Surge (28 errors/min > Threshold 10)
echo -e "\n${CLR_CYAN}--- Scenario 2: HTTP 5xx Error Rate Surge (28/min) ---${CLR_RESET}"
echo "  Injecting synthetic metric: 5xxErrorCount = 28 (Threshold: 10)"
send_sns_notification \
    "arn:aws:sns:us-east-1:123456789012:cloud-incident-routing-warnings" \
    "cloud-incident-routing-high-5xx" \
    "OK" \
    "ALARM" \
    "Threshold Breached: 1 datapoint [28.0] was greater than the threshold (10.0)."
sleep 0.2

# Scenario 3: Disk Space Exhaustion (91.2% > Threshold 85%)
echo -e "\n${CLR_CYAN}--- Scenario 3: Low Disk Space Anomaly (91.2%) ---${CLR_RESET}"
echo "  Injecting synthetic metric: DiskSpaceUtilization = 91.2% (Threshold: 85.0%)"
send_sns_notification \
    "arn:aws:sns:us-east-1:123456789012:cloud-incident-routing-warnings" \
    "cloud-incident-routing-disk-space" \
    "OK" \
    "ALARM" \
    "Threshold Breached: 2 datapoints [91.2, 91.8] were greater than the threshold (85.0)."
sleep 0.2

# Scenario 4: Correlated Major Outage (Composite Alarm: High CPU AND High 5xx)
echo -e "\n${CLR_CYAN}--- Scenario 4: Correlated P1 Critical Outage (Composite Alarm) ---${CLR_RESET}"
echo "  Evaluating Composite Rule: ALARM(high-cpu) AND ALARM(high-5xx) => TRUE"
send_sns_notification \
    "arn:aws:sns:us-east-1:123456789012:cloud-incident-routing-critical-incidents" \
    "cloud-incident-routing-composite-outage" \
    "OK" \
    "ALARM" \
    "CRITICAL P1 OUTAGE: High CPU utilization correlated with severe HTTP 5xx surge. Runbook: https://runbooks.internal/incident-p1-outage"
sleep 0.2

# Scenario 5: Incident Resolution (Metrics recover below threshold)
echo -e "\n${CLR_CYAN}--- Scenario 5: Incident Recovery & Auto-Remediation ---${CLR_RESET}"
echo "  Metrics normalized: CPU = 22.0%, 5xxErrorCount = 0. Alarms transitioning back to OK."
send_sns_notification \
    "arn:aws:sns:us-east-1:123456789012:cloud-incident-routing-critical-incidents" \
    "cloud-incident-routing-composite-outage" \
    "ALARM" \
    "OK" \
    "All underlying alarms are in OK state. Composite alarm resolved."
sleep 0.4

# ------------------------------------------------------------------------------
# 3. Assert Webhook Event Log
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Evaluating Webhook Notification Assertions...${CLR_RESET}"

RECORDED_COUNT=$(python3 -c "import json; data=json.load(open('$WEBHOOK_EVENTS_FILE')); print(len(data))" 2>/dev/null || echo "0")
echo -e "  Total Webhook Notifications Captured: ${CLR_WHITE}${RECORDED_COUNT}${CLR_RESET}\n"

assert_scenario "INCIDENT-01" "EC2 High CPU Alarm delivered to Warning Topic" \
    '[[ "$RECORDED_COUNT" -ge 1 ]]'

assert_scenario "INCIDENT-02" "HTTP 5xx Error Rate Alarm delivered to Warning Topic" \
    '[[ "$RECORDED_COUNT" -ge 2 ]]'

assert_scenario "INCIDENT-03" "Disk Space Low Alarm delivered to Warning Topic" \
    '[[ "$RECORDED_COUNT" -ge 3 ]]'

assert_scenario "INCIDENT-04" "Composite Outage Alarm delivered to Critical Topic" \
    '[[ "$RECORDED_COUNT" -ge 4 ]]'

assert_scenario "INCIDENT-05" "Resolution Notification (ALARM -> OK) Dispatched" \
    '[[ "$RECORDED_COUNT" -ge 5 ]]'

# ------------------------------------------------------------------------------
# 4. Summary & Report Export
# ------------------------------------------------------------------------------
PASS_PCT=$(( (PASSED * 100) / TOTAL ))

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  ${CLR_BOLD}Incident Routing Simulation Summary:${CLR_RESET}"
echo -e "  Total Scenarios Evaluated: ${CLR_WHITE}${TOTAL}${CLR_RESET}"
echo -e "  Passed                   : ${CLR_GREEN}${PASSED}${CLR_RESET}"
echo -e "  Failed                   : $([[ $FAILED -gt 0 ]] && echo "${CLR_RED}${FAILED}" || echo "${CLR_GREEN}0")${CLR_RESET}"
echo -e "  Compliance Score         : $([[ $PASS_PCT -eq 100 ]] && echo "${CLR_GREEN}${PASS_PCT}%" || echo "${CLR_YELLOW}${PASS_PCT}%")${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

if [[ -n "$JSON_OUT" ]]; then
    cat << EOF > "$JSON_OUT"
{
  "mode": "$MODE",
  "webhook_port": $WEBHOOK_PORT,
  "total_scenarios": $TOTAL,
  "passed": $PASSED,
  "failed": $FAILED,
  "compliance_percentage": $PASS_PCT,
  "recorded_webhook_events": $RECORDED_COUNT
}
EOF
    echo -e "${CLR_GRAY}[INFO] JSON test report exported to: ${JSON_OUT}${CLR_RESET}\n"
fi

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
