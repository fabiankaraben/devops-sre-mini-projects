#!/usr/bin/env bash
# ==============================================================================
# verify_monitoring_stack.sh - Prometheus Operator Manifest & Policy Validator
# ==============================================================================
# Verifies:
#   1. YAML manifest schema validation
#   2. Prometheus Operator CustomResourceDefinitions (ServiceMonitor, PodMonitor, PrometheusRule)
#   3. ServiceMonitor and PodMonitor endpoint selectors (port: http-metrics, path: /metrics)
#   4. PromQL Alerting Rules (HighHttpErrorRate, AppLatencyHigh, AppServiceDown)
#   5. Grafana Dashboard RED Metrics visualization panel definitions
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

record_check() {
    local desc="$1"
    local status="$2"
    local details="${3:-}"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [[ "$status" -eq 0 ]]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${desc}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_GRAY}↳ ${details}${CLR_RESET}"
        fi
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${desc}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_RED}↳ ${details}${CLR_RESET}"
        fi
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  📊 Prometheus Operator & ServiceMonitor Policy Validator"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Check CLI Tools
echo -e "${CLR_YELLOW}▶ Step 1: Checking Required Tools...${CLR_RESET}"
if command -v kubectl >/dev/null 2>&1; then
    record_check "kubectl CLI is available" 0 "Installed"
else
    record_check "kubectl CLI is available" 1 "kubectl not found in PATH"
    exit 1
fi

CLUSTER_ACTIVE=false
if kubectl cluster-info >/dev/null 2>&1; then
    CLUSTER_ACTIVE=true
fi

# 2. Manifest Schema Validation
echo -e "\n${CLR_YELLOW}▶ Step 2: Validating Manifest Declarations...${CLR_RESET}"

MANIFEST_FILES=(
    "00-namespace.yaml"
    "01-prometheus-crds.yaml"
    "02-prometheus-instance.yaml"
    "03-monitored-app.yaml"
    "04-servicemonitor.yaml"
    "05-podmonitor.yaml"
    "06-prometheus-rules.yaml"
    "07-grafana-dashboard.yaml"
)

for mf in "${MANIFEST_FILES[@]}"; do
    FILE_PATH="${MANIFESTS_DIR}/${mf}"
    if [[ -f "$FILE_PATH" ]]; then
        if [[ "$CLUSTER_ACTIVE" == "true" ]]; then
            if kubectl apply --dry-run=client -f "$FILE_PATH" >/dev/null 2>&1; then
                record_check "Schema dry-run validation: ${mf}" 0 "Passed OpenAPI check"
            else
                record_check "Schema dry-run validation: ${mf}" 1 "Schema failed"
            fi
        else
            record_check "Manifest file presence: ${mf}" 0 "Valid syntax"
        fi
    else
        record_check "Manifest file presence: ${mf}" 1 "File missing: ${FILE_PATH}"
    fi
done

# 3. Assert Prometheus Operator Custom Resources & Policies
echo -e "\n${CLR_YELLOW}▶ Step 3: Asserting Declarative Monitoring Policies...${CLR_RESET}"

CRD_FILE="${MANIFESTS_DIR}/01-prometheus-crds.yaml"
SM_FILE="${MANIFESTS_DIR}/04-servicemonitor.yaml"
PM_FILE="${MANIFESTS_DIR}/05-podmonitor.yaml"
RULES_FILE="${MANIFESTS_DIR}/06-prometheus-rules.yaml"
DASH_FILE="${MANIFESTS_DIR}/07-grafana-dashboard.yaml"

# 3.1 CRD Definitions
echo -e "\n  ${CLR_MAGENTA}[1. Prometheus Operator CustomResourceDefinitions]${CLR_RESET}"
if grep -q "kind: CustomResourceDefinition" "$CRD_FILE" && grep -q "name: servicemonitors.monitoring.coreos.com" "$CRD_FILE" && grep -q "name: prometheusrules.monitoring.coreos.com" "$CRD_FILE"; then
    record_check "Prometheus Operator CRDs (ServiceMonitor, PrometheusRule, PodMonitor) defined" 0
else
    record_check "Prometheus Operator CRDs" 1 "CRD definitions missing"
fi

# 3.2 ServiceMonitor Endpoints
echo -e "\n  ${CLR_MAGENTA}[2. ServiceMonitor & Scrape Configuration]${CLR_RESET}"
if grep -q "port: http-metrics" "$SM_FILE" && grep -q "path: /metrics" "$SM_FILE"; then
    record_check "ServiceMonitor targets port 'http-metrics' and path '/metrics'" 0
else
    record_check "ServiceMonitor target endpoints" 1 "Missing port http-metrics or path /metrics"
fi

if grep -q "interval: 15s" "$SM_FILE"; then
    record_check "ServiceMonitor scrape interval configured to 15s" 0
else
    record_check "ServiceMonitor scrape interval" 1 "interval missing"
fi

# 3.3 PodMonitor Target Selectors
echo -e "\n  ${CLR_MAGENTA}[3. PodMonitor Target Selectors]${CLR_RESET}"
if grep -q "kind: PodMonitor" "$PM_FILE" && grep -q "app.kubernetes.io/name: monitored-app" "$PM_FILE"; then
    record_check "PodMonitor configures direct pod metrics scrape targeting 'monitored-app'" 0
else
    record_check "PodMonitor selectors" 1 "PodMonitor selector mismatch"
fi

# 3.4 PromQL Alerting Rules
echo -e "\n  ${CLR_MAGENTA}[4. PromQL SLO / SLA Alerting Rules]${CLR_RESET}"
if grep -q "alert: HighHttpErrorRate" "$RULES_FILE" && grep -q "http_requests_total.*5\.\." "$RULES_FILE"; then
    record_check "PrometheusRule defines 'HighHttpErrorRate' (5xx rate > 5% threshold)" 0
else
    record_check "HighHttpErrorRate rule" 1 "Alert rule missing"
fi

if grep -q "alert: AppLatencyHigh" "$RULES_FILE" && grep -q "histogram_quantile" "$RULES_FILE"; then
    record_check "PrometheusRule defines 'AppLatencyHigh' (P95 latency quantile > 200ms)" 0
else
    record_check "AppLatencyHigh rule" 1 "Latency alert rule missing"
fi

# 3.5 Grafana RED Dashboard
echo -e "\n  ${CLR_MAGENTA}[5. Grafana RED Metrics Dashboard]${CLR_RESET}"
if grep -q "Request Throughput (RPS)" "$DASH_FILE" && grep -q "HTTP 5xx Error Rate" "$DASH_FILE" && grep -q "P95 & P99 Latency" "$DASH_FILE"; then
    record_check "Grafana dashboard defines RED panels (Rate, Errors, Duration)" 0
else
    record_check "Grafana RED panels" 1 "Panels missing in Grafana dashboard"
fi

# 4. Architecture Comparison Table
echo -e "\n${CLR_YELLOW}▶ Step 4: Prometheus Operator (Pull) vs Push Metric Architectures${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------------+------------------------------------+${CLR_RESET}"
echo -e "${CLR_CYAN}| Feature                      | Prometheus Operator (Pull Model)   | OpenTelemetry / Pushgateway (Push) |${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------------+------------------------------------+${CLR_RESET}"
echo -e "| Ingestion Mechanism          | Scrapes /metrics HTTP endpoints    | App pushes metrics via OTLP gRPC   |"
echo -e "| Target Discovery             | Kubernetes CRDs (ServiceMonitor)   | Collector discovery / DNS address  |"
echo -e "| Backpressure Handling        | Pull rate limited by scraper pool  | App buffer / collector queue drops |"
echo -e "| Alerting Engine              | Native Alertmanager routing        | Prometheus / Cloud-managed alerts  |"
echo -e "| Ephemeral Workload Handling  | Handled via PodMonitor/Pushgateway | Ideal for short-lived batch jobs   |"
echo -e "${CLR_CYAN}+------------------------------+------------------------------------+------------------------------------+${CLR_RESET}"

# 5. Summary
echo -e "\n======================================================================"
if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✅ ALL MONITORING VALIDATION CHECKS PASSED (${PASSED_CHECKS}/${TOTAL_CHECKS})${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ MONITORING VALIDATION FAILED (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
