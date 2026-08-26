#!/usr/bin/env bash
# ==============================================================================
# pipeline_health_check.sh - Automated Pipeline Verification Suite (08-07)
# ==============================================================================
# Verifies the end-to-end OpenTelemetry Collector pipeline:
# 1. Collector extension health check (:13133) and internal metrics (:8888)
# 2. Emits synthetic workloads (Standard orders, Sensitive data, Load simulation)
# 3. Validates Prometheus scraping of Collector-exported application metrics (:8889)
# 4. Validates Jaeger trace indexing, attribute enrichment, PII masking & filtering
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

APP_URL="http://localhost:8080"
COLLECTOR_HEALTH_URL="http://localhost:13133"
COLLECTOR_METRICS_URL="http://localhost:8888/metrics"
COLLECTOR_APP_METRICS_URL="http://localhost:8889/metrics"
PROMETHEUS_API_URL="http://localhost:9090/api/v1"
JAEGER_API_URL="http://localhost:16686/api"

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
echo "  🔭 OpenTelemetry Collector Pipeline - Automated Health Check"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Collector Liveness & Internal Health Verification
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking Collector Health Extensions & Internal Metrics...${CLR_RESET}"

# A. Health check extension probe
HEALTH_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$COLLECTOR_HEALTH_URL/" || echo "000")
if [[ "$HEALTH_HTTP_CODE" == "200" ]]; then
    record_pass "Collector Health Extension" "Health probe returned HTTP 200 OK at $COLLECTOR_HEALTH_URL"
else
    record_fail "Collector Health Extension" "Expected HTTP 200 from $COLLECTOR_HEALTH_URL, got $HEALTH_HTTP_CODE"
fi

# B. Internal metrics exposition (:8888)
INTERNAL_METRICS=$(curl -s "$COLLECTOR_METRICS_URL" || true)
if echo "$INTERNAL_METRICS" | grep -q "otelcol_process_uptime"; then
    record_pass "Collector Internal Metrics" "Successfully scraped internal operational metrics from $COLLECTOR_METRICS_URL"
else
    record_fail "Collector Internal Metrics" "Missing 'otelcol_process_uptime' in $COLLECTOR_METRICS_URL"
fi

# C. Sample application health check
APP_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$APP_URL/healthz" || echo "000")
if [[ "$APP_HTTP_CODE" == "200" ]]; then
    record_pass "Application Health" "Sample application is reachable at $APP_URL"
else
    record_fail "Application Health" "Application unreachable at $APP_URL (HTTP $APP_HTTP_CODE)"
fi

# ------------------------------------------------------------------------------
# 2. Emit Telemetry Traffic (Traces, Metrics, Sensitive Data)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Emitting Synthetic Workloads to OTel Collector Pipeline...${CLR_RESET}"

# A. Standard order transaction
echo "  [1/4] Dispatched standard order transaction..."
ORDER_RESP=$(curl -s -X POST "$APP_URL/api/orders" \
  -H "Content-Type: application/json" \
  -d '{"customer_id": "cust-verify-101", "customer_tier": "enterprise", "currency": "USD"}')
STANDARD_TRACE_ID=$(echo "$ORDER_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('trace_id', ''))" 2>/dev/null || echo "")

if [[ -n "$STANDARD_TRACE_ID" ]]; then
    record_pass "Order Transaction" "Created standard order. Trace ID: ${STANDARD_TRACE_ID}"
else
    record_fail "Order Transaction" "Failed to generate standard order: $ORDER_RESP"
fi

# B. Sensitive data transaction (Credit Card & API Key)
echo "  [2/4] Dispatched sensitive order transaction (PII / Secrets testing)..."
SENSITIVE_RESP=$(curl -s -X POST "$APP_URL/api/orders/sensitive" \
  -H "Content-Type: application/json" \
  -d '{"customer_id": "cust-pii-test", "credit_card": "4111-2222-3333-4444", "api_key": "secret_token_12345", "amount": 199.99}')
SENSITIVE_TRACE_ID=$(echo "$SENSITIVE_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('trace_id', ''))" 2>/dev/null || echo "")

if [[ -n "$SENSITIVE_TRACE_ID" ]]; then
    record_pass "Sensitive Transaction" "Emitted sensitive payload. Trace ID: ${SENSITIVE_TRACE_ID}"
else
    record_fail "Sensitive Transaction" "Failed to submit sensitive order: $SENSITIVE_RESP"
fi

# C. Product catalog browsing & Load burst
echo "  [3/4] Dispatched product catalog browsing requests..."
curl -s "$APP_URL/api/products?category=books" >/dev/null
curl -s "$APP_URL/api/products?category=electronics" >/dev/null

echo "  [4/4] Dispatched load burst simulation..."
curl -s -X POST "$APP_URL/api/simulate-load?count=8" >/dev/null

# D. Generate health check requests (which must be filtered by the Collector!)
curl -s "$APP_URL/healthz" >/dev/null
curl -s "$APP_URL/healthz" >/dev/null

# ------------------------------------------------------------------------------
# 3. Allow Collector Batch Processor and Prometheus Scraper to Flush
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Awaiting Collector Batch Processor & Prometheus Scrape Cycle (4s)...${CLR_RESET}"
sleep 4

# ------------------------------------------------------------------------------
# 4. Validate Application & Internal Metrics in Prometheus
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Validating Metrics Delivery in Prometheus TSDB (:9090)...${CLR_RESET}"

# A. Check App Metrics Exporter (:8889)
APP_METRICS_EXPORTER=$(curl -s "$COLLECTOR_APP_METRICS_URL" || true)
if echo "$APP_METRICS_EXPORTER" | grep -q "otel_orders_total"; then
    record_pass "Prometheus Exporter (:8889)" "OTel Collector successfully transformed and exposed 'otel_orders_total' on port 8889"
else
    record_fail "Prometheus Exporter (:8889)" "Missing 'otel_orders_total' on $COLLECTOR_APP_METRICS_URL"
fi

# B. Query Prometheus API for otel_orders_total
PROM_QUERY_ORDERS=$(curl -s -G "${PROMETHEUS_API_URL}/query" --data-urlencode "query=otel_orders_total")
ORDERS_COUNT=$(echo "$PROM_QUERY_ORDERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
total = sum(float(r['value'][1]) for r in results) if results else 0
print(int(total))
" 2>/dev/null || echo "0")

if [ "$ORDERS_COUNT" -gt 0 ]; then
    record_pass "Prometheus App Metric Query" "Query 'otel_orders_total' returned active series with accumulated count: ${ORDERS_COUNT}"
else
    record_fail "Prometheus App Metric Query" "Query 'otel_orders_total' returned 0 or empty result from Prometheus API"
fi

# C. Query Prometheus API for Collector Ingestion Counter
PROM_QUERY_COLLECTOR=$(curl -s -G "${PROMETHEUS_API_URL}/query" --data-urlencode "query=otelcol_receiver_accepted_spans")
COLLECTOR_SPANS=$(echo "$PROM_QUERY_COLLECTOR" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
total = sum(float(r['value'][1]) for r in results) if results else 0
print(int(total))
" 2>/dev/null || echo "0")

if [ "$COLLECTOR_SPANS" -gt 0 ]; then
    record_pass "Collector Pipeline Performance" "Collector metric 'otelcol_receiver_accepted_spans' confirmed ${COLLECTOR_SPANS} spans processed"
else
    record_fail "Collector Pipeline Performance" "No accepted spans recorded in 'otelcol_receiver_accepted_spans'"
fi

# ------------------------------------------------------------------------------
# 5. Validate Traces in Jaeger & Attribute Processing
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Validating Traces in Jaeger, Attribute Ingestion & Masking...${CLR_RESET}"

# A. Verify Standard Order Trace in Jaeger
JAEGER_TRACE_RESP=$(curl -s "${JAEGER_API_URL}/traces/${STANDARD_TRACE_ID}" || true)
SPANS_COUNT=$(echo "$JAEGER_TRACE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
traces = data.get('data', [])
if traces:
    print(len(traces[0].get('spans', [])))
else:
    print(0)
" 2>/dev/null || echo "0")

if [ "$SPANS_COUNT" -gt 0 ]; then
    record_pass "Jaeger Trace Delivery" "Standard trace (${STANDARD_TRACE_ID}) indexed in Jaeger with ${SPANS_COUNT} spans"
else
    record_fail "Jaeger Trace Delivery" "Standard trace (${STANDARD_TRACE_ID}) not found in Jaeger"
fi

# B. Verify Attribute Processor Injections (environment, datacenter, service.namespace)
ATTRIBUTE_CHECK=$(echo "$JAEGER_TRACE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
traces = data.get('data', [])
if not traces:
    print('NO_TRACE')
    sys.exit(0)

trace = traces[0]
spans = trace.get('spans', [])
processes = trace.get('processes', {})

has_env = False
has_dc = False
has_ns = False

for s in spans:
    for t in s.get('tags', []):
        if t.get('key') == 'environment' and t.get('value') == 'production':
            has_env = True
        if t.get('key') == 'datacenter' and t.get('value') == 'us-east-1':
            has_dc = True

for p in processes.values():
    for t in p.get('tags', []):
        if t.get('key') == 'service.namespace' and t.get('value') == 'ecommerce-telemetry':
            has_ns = True

print(f'env={has_env},dc={has_dc},ns={has_ns}')
" 2>/dev/null || echo "ERROR")

if [[ "$ATTRIBUTE_CHECK" == *"env=True"* ]] && [[ "$ATTRIBUTE_CHECK" == *"dc=True"* ]]; then
    record_pass "Attribute Processor Injection" "Collector successfully injected 'environment=production' and 'datacenter=us-east-1'"
else
    record_fail "Attribute Processor Injection" "Collector attribute injection failed. Details: ${ATTRIBUTE_CHECK}"
fi

# C. Verify Sensitive Data Redaction & API Key Deletion
SENSITIVE_TRACE_RESP=$(curl -s "${JAEGER_API_URL}/traces/${SENSITIVE_TRACE_ID}" || true)
MASKING_CHECK=$(echo "$SENSITIVE_TRACE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
traces = data.get('data', [])
if not traces:
    print('NO_TRACE')
    sys.exit(0)

trace = traces[0]
spans = trace.get('spans', [])

card_redacted = False
api_key_deleted = True

for s in spans:
    for t in s.get('tags', []):
        if t.get('key') == 'credit_card':
            if t.get('value') == '[REDACTED]':
                card_redacted = True
            elif '4111' in str(t.get('value')):
                card_redacted = False
        if t.get('key') == 'api_key':
            api_key_deleted = False

print(f'card_redacted={card_redacted},api_key_deleted={api_key_deleted}')
" 2>/dev/null || echo "ERROR")

if [[ "$MASKING_CHECK" == *"card_redacted=True"* ]] && [[ "$MASKING_CHECK" == *"api_key_deleted=True"* ]]; then
    record_pass "PII & Secret Sanitization" "Collector masked 'credit_card' to '[REDACTED]' and deleted 'api_key' attribute"
else
    record_fail "PII & Secret Sanitization" "Sanitization failed. Details: ${MASKING_CHECK}"
fi

# D. Verify Filter Processor Dropped /healthz Spans
HEALTH_TRACES=$(curl -s "${JAEGER_API_URL}/traces?service=sample-order-service&operation=GET%20%2Fhealthz" || true)
HEALTH_TRACE_COUNT=$(echo "$HEALTH_TRACES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data.get('data', [])))
" 2>/dev/null || echo "0")

if [[ "$HEALTH_TRACE_COUNT" -eq 0 ]]; then
    record_pass "Span Filter Processor" "Filter processor successfully dropped noisy 'GET /healthz' spans (0 in Jaeger)"
else
    record_fail "Span Filter Processor" "Found ${HEALTH_TRACE_COUNT} unwanted '/healthz' traces in Jaeger"
fi

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  📊 Pipeline Verification Summary"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  Total Test Assertions: ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  Passed Assertions:     ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
if [ "$FAILED_TESTS" -gt 0 ]; then
    echo -e "  Failed Assertions:     ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
else
    echo -e "  Failed Assertions:     ${CLR_GREEN}${CLR_BOLD}0${CLR_RESET}"
fi

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}✅ SUCCESS: OpenTelemetry Collector Telemetry Pipeline is operating perfectly!${CLR_RESET}"
    echo -e "🔗 Jaeger UI:        ${CLR_CYAN}http://localhost:16686${CLR_RESET}"
    echo -e "🔗 Prometheus UI:    ${CLR_CYAN}http://localhost:9090${CLR_RESET}"
    echo -e "🔗 Collector Health: ${CLR_CYAN}http://localhost:13133/${CLR_RESET}"
    echo -e "🔗 App Metrics Scrape: ${CLR_CYAN}http://localhost:8889/metrics${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ FAILURE: ${FAILED_TESTS} pipeline assertions failed.${CLR_RESET}\n"
    exit 1
fi
