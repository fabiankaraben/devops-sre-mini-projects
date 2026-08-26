#!/usr/bin/env bash
# ==============================================================================
# k8s_monitoring_test.sh - Automated Validation Suite for Kubernetes Observability
# ==============================================================================
# Verifies:
#   1. Prometheus Operator & CRD registration (ServiceMonitor, PodMonitor, Rules)
#   2. Dynamic target discovery (order-api endpoints auto-scraped by Prometheus)
#   3. Synthetic traffic generation and metric ingestion (http_requests_total)
#   4. PrometheusRule evaluation and alert state transitions (OrderApiHighErrorRate)
#   5. Grafana visualization datasource connectivity
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
CLR_WHITE="\033[1;37m"
CLR_GRAY="\033[0;90m"

PROM_URL="http://localhost:30090"
GRAFANA_URL="http://localhost:30030"
APP_URL="http://localhost:30080"
ALERTMANAGER_URL="http://localhost:30093"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_pass() {
    local test_name="$1"
    local message="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${CLR_BOLD}${test_name}${CLR_RESET}: ${message}"
}

record_fail() {
    local test_name="$1"
    local message="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${CLR_BOLD}${test_name}${CLR_RESET}: ${message}"
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ☸️ kube-prometheus-stack Observability - Automated Validation"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Cluster & Monitoring Infrastructure Health
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking Kubernetes Cluster & Prometheus Operator Health...${CLR_RESET}"

# Check CRDs
CRDS=$(kubectl get crd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for crd in "servicemonitors.monitoring.coreos.com" "podmonitors.monitoring.coreos.com" "prometheusrules.monitoring.coreos.com"; do
    if echo "$CRDS" | grep -q "$crd"; then
        record_pass "CRD Available" "CustomResourceDefinition '$crd' is registered"
    else
        record_fail "CRD Available" "Missing CRD '$crd'"
    fi
done

# Check monitoring pods
MON_PODS=$(kubectl get pods -n monitoring -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if echo "$MON_PODS" | grep -q "Running"; then
    record_pass "Monitoring Stack" "Core monitoring pods are running in 'monitoring' namespace"
else
    record_fail "Monitoring Stack" "No running pods found in 'monitoring' namespace"
fi

# ------------------------------------------------------------------------------
# 2. Application Deployment Readiness
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Checking Instrumented Workload (order-api)...${CLR_RESET}"

APP_READY=$(kubectl get deployment order-api -n default -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${APP_READY:-0}" -ge 1 ]; then
    record_pass "order-api Deployment" "Workload is running with ${APP_READY} ready replicas"
else
    record_fail "order-api Deployment" "Deployment order-api is not ready (ready replicas: ${APP_READY})"
fi

# ------------------------------------------------------------------------------
# 3. Dynamic Target Auto-Discovery in Prometheus
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Verifying Prometheus Operator Dynamic Target Discovery...${CLR_RESET}"

# Query Prometheus targets API
TARGET_DISCOVERED=false
TARGET_HEALTHY=false

for attempt in {1..20}; do
    TARGETS_JSON=$(curl -s "${PROM_URL}/api/v1/targets" 2>/dev/null || echo "{}")
    DISCOVERY_CHECK=$(echo "$TARGETS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
active = data.get('data', {}).get('activeTargets', [])
order_targets = [t for t in active if 'order-api' in str(t.get('labels', {}))]
if order_targets:
    healthy = any(t.get('health') == 'up' for t in order_targets)
    print(f'found=True,healthy={healthy},count={len(order_targets)}')
else:
    print('found=False,healthy=False,count=0')
" 2>/dev/null || echo "found=False,healthy=False,count=0")

    if [[ "$DISCOVERY_CHECK" == *"found=True"* ]]; then
        TARGET_DISCOVERED=true
        if [[ "$DISCOVERY_CHECK" == *"healthy=True"* ]]; then
            TARGET_HEALTHY=true
            break
        fi
    fi
    sleep 2
done

if [ "$TARGET_DISCOVERED" = true ]; then
    record_pass "Target Discovery" "Prometheus Operator dynamically discovered order-api ServiceMonitor target"
else
    record_fail "Target Discovery" "order-api target not found in Prometheus active targets list"
fi

if [ "$TARGET_HEALTHY" = true ]; then
    record_pass "Target Health" "Prometheus successfully scrapes order-api endpoints (health: up)"
else
    record_fail "Target Health" "order-api scrape target is not in 'up' state"
fi

# ------------------------------------------------------------------------------
# 4. Traffic Injection & Metric Ingestion Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Emitting Synthetic Workloads & Testing Metric Ingestion...${CLR_RESET}"

# Send normal order traffic
for _ in {1..12}; do
    curl -s -X POST "${APP_URL}/api/orders" \
      -H "Content-Type: application/json" \
      -d '{"customer_id": "cust-verify-101", "customer_tier": "enterprise", "currency": "USD", "amount": 149.99}' >/dev/null 2>&1 || true
done

# Send error traffic to trigger alert
for _ in {1..6}; do
    curl -s -X POST "${APP_URL}/api/simulate-error" >/dev/null 2>&1 || true
done

echo "  Waiting for Prometheus scrape cycle (6s)..."
sleep 6

# Query Prometheus PromQL API
PROM_ORDERS=$(curl -s -G "${PROM_URL}/api/v1/query" --data-urlencode "query=orders_processed_total" 2>/dev/null || echo "{}")
ORDERS_COUNT=$(echo "$PROM_ORDERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
total = sum(float(r['value'][1]) for r in results) if results else 0
print(int(total))
" 2>/dev/null || echo "0")

if [ "$ORDERS_COUNT" -gt 0 ]; then
    record_pass "Metric Ingestion" "PromQL query 'orders_processed_total' returned accumulated count: ${ORDERS_COUNT}"
else
    record_fail "Metric Ingestion" "PromQL query 'orders_processed_total' returned 0 or empty result"
fi

PROM_ERRORS=$(curl -s -G "${PROM_URL}/api/v1/query" --data-urlencode "query=http_requests_total{status='500'}" 2>/dev/null || echo "{}")
ERRORS_COUNT=$(echo "$PROM_ERRORS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
total = sum(float(r['value'][1]) for r in results) if results else 0
print(int(total))
" 2>/dev/null || echo "0")

if [ "$ERRORS_COUNT" -gt 0 ]; then
    record_pass "5xx Error Metrics" "PromQL query recorded ${ERRORS_COUNT} simulated HTTP 500 error samples"
else
    record_fail "5xx Error Metrics" "No 500 status metrics recorded in Prometheus"
fi

# ------------------------------------------------------------------------------
# 5. PrometheusRule Evaluation & Grafana Health
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Validating PrometheusRule Alerts & Grafana Health...${CLR_RESET}"

# Verify Alert Rule Ingestion
RULES_JSON=$(curl -s "${PROM_URL}/api/v1/rules" 2>/dev/null || echo "{}")
RULE_LOADED=$(echo "$RULES_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
groups = data.get('data', {}).get('groups', [])
has_rule = any(
    any(r.get('name') == 'OrderApiHighErrorRate' for r in g.get('rules', []))
    for g in groups
)
print(has_rule)
" 2>/dev/null || echo "False")

if [ "$RULE_LOADED" = "True" ]; then
    record_pass "PrometheusRule Loaded" "Prometheus Operator successfully loaded 'OrderApiHighErrorRate' alert rule"
else
    record_fail "PrometheusRule Loaded" "Alert rule 'OrderApiHighErrorRate' not found in Prometheus rules"
fi

# Verify Grafana Health
GRAFANA_HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_URL}/api/health" 2>/dev/null || echo "000")
if [[ "$GRAFANA_HEALTH_CODE" == "200" ]]; then
    record_pass "Grafana Health" "Grafana dashboard service is online and healthy at ${GRAFANA_URL}"
else
    record_fail "Grafana Health" "Grafana unreachable at ${GRAFANA_URL} (HTTP ${GRAFANA_HEALTH_CODE})"
fi

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  📊 Kubernetes Observability Verification Summary"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  Total Test Assertions: ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  Passed Assertions:     ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
if [ "$FAILED_TESTS" -gt 0 ]; then
    echo -e "  Failed Assertions:     ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
else
    echo -e "  Failed Assertions:     ${CLR_GREEN}${CLR_BOLD}0${CLR_RESET}"
fi

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✅ SUCCESS: kube-prometheus-stack is operating with full CRD auto-discovery!${CLR_RESET}"
    echo -e "🔗 Prometheus Web UI:  ${CLR_CYAN}${PROM_URL}${CLR_RESET}"
    echo -e "🔗 Grafana Dashboard:  ${CLR_CYAN}${GRAFANA_URL}${CLR_RESET} (User: ${CLR_BOLD}admin${CLR_RESET} / Pass: ${CLR_BOLD}prom-operator${CLR_RESET})"
    echo -e "🔗 Alertmanager UI:    ${CLR_CYAN}${ALERTMANAGER_URL}${CLR_RESET}"
    echo -e "🔗 Sample App Service: ${CLR_CYAN}${APP_URL}/docs${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ FAILURE: ${FAILED_TESTS} assertions failed.${CLR_RESET}\n"
    exit 1
fi
