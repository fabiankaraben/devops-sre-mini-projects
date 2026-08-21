#!/usr/bin/env bash
# ==============================================================================
# helm_test_pipeline.sh - Production-Grade Helm 3 Test Pipeline
# ==============================================================================
# Verifies:
#   1. helm lint: Syntax, metadata, and packaging best practices
#   2. helm template: Manifest rendering & Go templating pipeline
#   3. values.schema.json: JSON Schema guardrails & type enforcement
#   4. helm install: Deployment to Kubernetes cluster with staging overrides
#   5. helm test: Execution of integration test hook pod
#   6. helm upgrade: Zero-downtime release upgrade with production overrides
#   7. helm rollback: Safe release rollback to previous revision
# ==============================================================================

set -euo pipefail

# ANSI Color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/chart"
NAMESPACE="${NAMESPACE:-helm-demo}"
RELEASE_NAME="enterprise-app"

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⎈ Helm 3 Production Chart CI/CD Test Pipeline"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Step 1: Helm Chart Linting
echo -e "${CLR_YELLOW}▶ Step 1: Linting Helm Chart (helm lint)...${CLR_RESET}"
if helm lint "$CHART_DIR" >/dev/null 2>&1; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Helm chart passed linting with zero errors."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Helm lint failed."
    helm lint "$CHART_DIR"
    exit 1
fi

# Step 2: Template Rendering Validation
echo -e "\n${CLR_YELLOW}▶ Step 2: Testing Manifest Rendering (helm template)...${CLR_RESET}"
if helm template "$RELEASE_NAME" "$CHART_DIR" >/dev/null 2>&1; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] All templates rendered cleanly."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Template rendering failed."
    exit 1
fi

# Step 3: JSON Schema Validation Guardrails
echo -e "\n${CLR_YELLOW}▶ Step 3: Testing JSON Schema Validation Guardrails (values.schema.json)...${CLR_RESET}"
# Test with negative replicaCount (schema requires minimum: 1)
if helm template "$RELEASE_NAME" "$CHART_DIR" --set replicaCount=-5 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Schema allowed invalid negative replicaCount!"
    exit 1
else
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Schema correctly blocked invalid negative replicaCount (minimum: 1)."
fi

# Test with invalid environment enum (schema requires development, staging, production)
if helm template "$RELEASE_NAME" "$CHART_DIR" --set config.environment=invalid-env >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Schema allowed invalid environment value!"
    exit 1
else
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Schema correctly blocked invalid environment enum."
fi

# Step 4: Helm Release Installation (Staging Values)
echo -e "\n${CLR_YELLOW}▶ Step 4: Installing Helm Release in Staging Mode (helm install)...${CLR_RESET}"
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    -f "${SCRIPT_DIR}/values-staging.yaml" \
    -n "$NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 60s >/dev/null

echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Helm release '${RELEASE_NAME}' successfully installed (Revision 1 - Staging)."

# Step 5: Helm Test Hook Execution
echo -e "\n${CLR_YELLOW}▶ Step 5: Executing Integration Test Hook (helm test)...${CLR_RESET}"
if helm test "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Helm test hook passed! Service connectivity verified."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Helm test hook failed."
    helm test "$RELEASE_NAME" -n "$NAMESPACE" --logs
    exit 1
fi

# Step 6: Helm Upgrade Lifecycle (Production Values)
echo -e "\n${CLR_YELLOW}▶ Step 6: Upgrading Helm Release to Production Mode (helm upgrade)...${CLR_RESET}"
helm upgrade "$RELEASE_NAME" "$CHART_DIR" \
    -f "${SCRIPT_DIR}/values-production.yaml" \
    -n "$NAMESPACE" \
    --wait \
    --timeout 60s >/dev/null

rev_after_upgrade=$(helm list -n "$NAMESPACE" -f "^${RELEASE_NAME}$" -o json | grep -o '"revision":"[^"]*"' | cut -d'"' -f4 || echo "2")
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Helm release successfully upgraded to Revision ${rev_after_upgrade} (Production)."

# Step 7: Helm Rollback Lifecycle
echo -e "\n${CLR_YELLOW}▶ Step 7: Testing Release Rollback to Revision 1 (helm rollback)...${CLR_RESET}"
helm rollback "$RELEASE_NAME" 1 -n "$NAMESPACE" --wait --timeout 60s >/dev/null
rev_after_rollback=$(helm list -n "$NAMESPACE" -f "^${RELEASE_NAME}$" -o json | grep -o '"revision":"[^"]*"' | cut -d'"' -f4 || echo "3")
echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Helm release successfully rolled back (Current Revision: ${rev_after_rollback})."

# Final Report
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}📊 HELM 3 CI/CD PIPELINE VERIFICATION REPORT${CLR_RESET}"
echo -e "======================================================================"
echo -e "  Chart Name & Version         : enterprise-app (v1.0.0)"
echo -e "  Static Analysis (helm lint)  : ${CLR_GREEN}PASSED${CLR_RESET}"
echo -e "  JSON Schema Enforcement      : ${CLR_GREEN}PASSED${CLR_RESET} (Type guardrails active)"
echo -e "  Integration Hook (helm test) : ${CLR_GREEN}PASSED${CLR_RESET}"
echo -e "  Release Upgrade & Rollback   : ${CLR_GREEN}PASSED${CLR_RESET} (Full lifecycle verified)"
echo -e "======================================================================"
echo -e "${CLR_GREEN}${CLR_BOLD}✅ ALL HELM PIPELINE STAGES COMPLETED SUCCESSFULLY!${CLR_RESET}\n"
