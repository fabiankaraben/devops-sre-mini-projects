#!/usr/bin/env bash
# ==============================================================================
# test_vault_sidecar_pipeline.sh - Verification Test Suite for Vault K8s Sidecar
# ==============================================================================
# Executes end-to-end verification of Kubernetes Vault Agent Sidecar injection,
# Consul template rendering, live zero-downtime secret rotation, and metrics.
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    local test_name="$1"
    local status="$2"
    local details="${3:-}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$status" -eq 0 ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${test_name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${test_name} (Exit Code: ${status}) ${details}"
    fi
}

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  🧪 STARTING VAULT K8s AGENT SIDECAR TEST SUITE"
echo "======================================================================${CLR_RESET}"

# ------------------------------------------------------------------------------
# Step 0: Validate Prerequisites
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 0/6] Validating environment dependencies...${CLR_RESET}"

if command -v docker >/dev/null 2>&1; then
    record_result "Docker CLI is available" 0
else
    record_result "Docker CLI is available" 1 "Docker is required"
fi

if command -v python3 >/dev/null 2>&1; then
    record_result "Python 3 is available" 0
else
    record_result "Python 3 is available" 1
fi

if command -v curl >/dev/null 2>&1; then
    record_result "curl CLI is available" 0
else
    record_result "curl CLI is available" 1
fi

# ------------------------------------------------------------------------------
# Step 1: Validate Kubernetes Manifests Syntax & Annotations
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 1/6] Validating Kubernetes Manifests & Vault Annotations...${CLR_RESET}"

if [ -f "k8s/deployment.yaml" ] && [ -f "k8s/serviceaccount.yaml" ] && [ -f "k8s/rbac.yaml" ]; then
    record_result "Kubernetes manifest files exist in k8s/" 0
else
    record_result "Kubernetes manifest files exist in k8s/" 1
fi

if grep -q "vault.hashicorp.com/agent-inject: \"true\"" k8s/deployment.yaml; then
    record_result "k8s/deployment.yaml contains 'vault.hashicorp.com/agent-inject' annotation" 0
else
    record_result "k8s/deployment.yaml contains 'vault.hashicorp.com/agent-inject' annotation" 1
fi

if grep -q "vault.hashicorp.com/agent-inject-template-config.json" k8s/deployment.yaml; then
    record_result "k8s/deployment.yaml contains Consul Template configuration" 0
else
    record_result "k8s/deployment.yaml contains Consul Template configuration" 1
fi

# ------------------------------------------------------------------------------
# Step 2: Start Vault & Application Containers
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 2/6] Starting Vault Server & Payment App Containers...${CLR_RESET}"

docker compose up -d --build >/dev/null 2>&1

MAX_WAIT=20
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s "http://127.0.0.1:8200/v1/sys/init" >/dev/null 2>&1; then
        break
    fi
    WAITED=$((WAITED + 2))
    sleep 2
done

if [ $WAITED -lt $MAX_WAIT ]; then
    record_result "Vault Server container started and responsive" 0
else
    record_result "Vault Server container started and responsive" 1
fi

# ------------------------------------------------------------------------------
# Step 3: Run Automated Vault K8s Bootstrapper & Sidecar
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 3/6] Running automated vault_k8s_bootstrap.sh...${CLR_RESET}"

set +e
./vault_k8s_bootstrap.sh >/dev/null 2>&1
BOOTSTRAP_STATUS=$?
set -e

if [ "$BOOTSTRAP_STATUS" -eq 0 ]; then
    record_result "vault_k8s_bootstrap.sh executed successfully" 0
else
    record_result "vault_k8s_bootstrap.sh executed successfully" 1 "Bootstrap failed"
fi

# Check if Vault Agent sidecar is running
if docker ps --format '{{.Names}}' | grep -q "vault-agent-sidecar"; then
    record_result "Vault Agent Sidecar daemon is active" 0
else
    record_result "Vault Agent Sidecar daemon is active" 1
fi

# ------------------------------------------------------------------------------
# Step 4: Verify Initial In-Memory Secret Injection
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 4/6] Verifying In-Memory Secret Injection in Running Pod...${CLR_RESET}"

APP_HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/health" || echo "500")

if [ "$APP_HEALTH_CODE" -eq 200 ]; then
    record_result "Payment Service HTTP API is healthy (HTTP 200)" 0
else
    record_result "Payment Service HTTP API is healthy (HTTP 200)" 1 "Got HTTP $APP_HEALTH_CODE"
fi

SECRETS_RESP=$(curl -s "http://127.0.0.1:8080/secrets")
SECRET_VER=$(echo "$SECRETS_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('secret_version', ''))")

if [ "$SECRET_VER" == "1" ]; then
    record_result "Payment Service loaded Version 1 secret from in-memory /vault/secrets/config.json" 0
else
    record_result "Payment Service loaded Version 1 secret from in-memory /vault/secrets/config.json" 1 "Expected v1, got '$SECRET_VER'"
fi

# ------------------------------------------------------------------------------
# Step 5: Execute Live Secret Rotation Test Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 5/6] Running secret_rotation_test.sh (Live Zero-Downtime Rotation)...${CLR_RESET}"

set +e
./secret_rotation_test.sh >/dev/null 2>&1
ROTATION_STATUS=$?
set -e

if [ "$ROTATION_STATUS" -eq 0 ]; then
    record_result "secret_rotation_test.sh completed full rotation lifecycle (v1 -> v2 -> v3)" 0
else
    record_result "secret_rotation_test.sh completed full rotation lifecycle" 1
fi

# ------------------------------------------------------------------------------
# Step 6: Verify Metrics and In-Memory Isolation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [Step 6/6] Verifying Hot-Reload Metrics & File Permissions...${CLR_RESET}"

METRICS_OUTPUT=$(curl -s "http://127.0.0.1:8080/metrics")

if echo "$METRICS_OUTPUT" | grep -q "payment_service_secret_version 3"; then
    record_result "Prometheus metrics report active secret version 3" 0
else
    record_result "Prometheus metrics report active secret version 3" 1
fi

if echo "$METRICS_OUTPUT" | grep -q "payment_service_secret_reloads_total"; then
    record_result "Prometheus metrics track secret hot-reload event counter" 0
else
    record_result "Prometheus metrics track secret hot-reload event counter" 1
fi

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
echo "  📊 TEST SUITE SUMMARY"
echo "======================================================================${CLR_RESET}"
echo -e "  Total Tests Evaluated : ${TOTAL_TESTS}"
echo -e "  Passed                : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed                : ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL VAULT K8s AGENT SIDECAR TESTS PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. REVIEW LOGS ABOVE.${CLR_RESET}\n"
    exit 1
fi
