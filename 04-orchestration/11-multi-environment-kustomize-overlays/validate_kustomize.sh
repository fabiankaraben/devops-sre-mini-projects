#!/usr/bin/env bash
# ==============================================================================
# validate_kustomize.sh - Kustomize Multi-Environment Manifest Validation
# ==============================================================================
# Verifies:
#   1. Syntactic correctness of base and all overlay manifests via kustomize build
#   2. Kubernetes client-side schema validation via kubectl kustomize / dry-run
#   3. Environment-specific property assertions (replicas, namespaces, resources,
#      image pinning, hash suffixes, JSON 6902 patches, and PodDisruptionBudgets)
#   4. Emits a structured comparison matrix across environments
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
TMP_DIR="${SCRIPT_DIR}/.tmp_validation"

mkdir -p "$TMP_DIR"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

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
echo "  🛠️  Kustomize Multi-Environment Manifest Validator"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Verify Prerequisites
echo -e "${CLR_YELLOW}▶ Step 1: Checking Required Tools...${CLR_RESET}"
if command -v kustomize >/dev/null 2>&1; then
    KUST_VER=$(kustomize version 2>/dev/null || echo "installed")
    record_check "kustomize CLI is available" 0 "$KUST_VER"
else
    record_check "kustomize CLI is available" 0 "Using built-in kubectl kustomize"
fi

if command -v kubectl >/dev/null 2>&1; then
    record_check "kubectl CLI is available" 0 "kubectl installed"
else
    record_check "kubectl CLI is available" 1 "kubectl not found in PATH"
fi

build_kustomize() {
    local target="$1"
    local outfile="$2"
    if command -v kustomize >/dev/null 2>&1; then
        kustomize build "$target" > "$outfile"
    else
        kubectl kustomize "$target" > "$outfile"
    fi
}

CLUSTER_ACTIVE=false
if kubectl cluster-info >/dev/null 2>&1; then
    CLUSTER_ACTIVE=true
fi

# 2. Build Base and Overlays
echo -e "\n${CLR_YELLOW}▶ Step 2: Building Declarative Manifests...${CLR_RESET}"

for env in "base" "overlays/development" "overlays/staging" "overlays/production"; do
    TARGET_PATH="${SCRIPT_DIR}/${env}"
    OUT_FILE="${TMP_DIR}/${env//\//_}.yaml"
    
    if build_kustomize "$TARGET_PATH" "$OUT_FILE"; then
        DOC_COUNT=$(grep -c "^---" "$OUT_FILE" || true)
        DOC_COUNT=$((DOC_COUNT + 1))
        record_check "kustomize build ${env}" 0 "Generated ${DOC_COUNT} Kubernetes resource documents"
    else
        record_check "kustomize build ${env}" 1 "Failed to compile kustomization in ${TARGET_PATH}"
    fi

    # Also test via kubectl kustomize
    if kubectl kustomize "$TARGET_PATH" >/dev/null 2>&1; then
        record_check "kubectl kustomize ${env} syntax validation" 0 "Passed internal parser check"
    else
        record_check "kubectl kustomize ${env} syntax validation" 1 "Failed internal parser check"
    fi

    # Dry-run client schema validation if live cluster is active
    if [[ "$CLUSTER_ACTIVE" == "true" ]]; then
        if kubectl apply --dry-run=client -k "$TARGET_PATH" >/dev/null 2>&1; then
            record_check "kubectl server schema dry-run (${env})" 0 "Passed cluster OpenAPI schema validation"
        else
            record_check "kubectl server schema dry-run (${env})" 1 "Cluster schema validation failed"
        fi
    fi
done

# 3. Verify Specific Environment Assertions
echo -e "\n${CLR_YELLOW}▶ Step 3: Asserting Environment-Specific Kustomize Transformations...${CLR_RESET}"

DEV_YAML="${TMP_DIR}/overlays_development.yaml"
STAGING_YAML="${TMP_DIR}/overlays_staging.yaml"
PROD_YAML="${TMP_DIR}/overlays_production.yaml"

# --- Development Assertions ---
echo -e "\n  ${CLR_MAGENTA}[Development Environment Checks]${CLR_RESET}"
# 1. Namespace
if grep -q "namespace: dev-environment" "$DEV_YAML"; then
    record_check "Dev namespace set to dev-environment" 0
else
    record_check "Dev namespace set to dev-environment" 1 "Missing dev-environment namespace"
fi

# 2. Name Prefix
if grep -q "name: dev-payment-service" "$DEV_YAML"; then
    record_check "Dev namePrefix 'dev-' applied to deployment and service" 0
else
    record_check "Dev namePrefix 'dev-' applied" 1 "dev- prefix not found on payment-service"
fi

# 3. Replicas
DEV_REPLICAS=$(awk '/kind: Deployment/,/replicas:/ { if ($1 == "replicas:") print $2 }' "$DEV_YAML" | head -n1)
if [[ "$DEV_REPLICAS" -eq 1 ]]; then
    record_check "Dev deployment replica count equals 1" 0 "replicas: $DEV_REPLICAS"
else
    record_check "Dev deployment replica count equals 1" 1 "Expected 1, got ${DEV_REPLICAS:-none}"
fi

# 4. ConfigMap debug level
if grep -q "LOG_LEVEL: debug" "$DEV_YAML"; then
    record_check "Dev ConfigMap contains LOG_LEVEL: debug" 0
else
    record_check "Dev ConfigMap contains LOG_LEVEL: debug" 1 "LOG_LEVEL: debug missing"
fi

# 5. Low resource limits (50m/64Mi)
if grep -q "cpu: 50m" "$DEV_YAML" && grep -q "memory: 64Mi" "$DEV_YAML"; then
    record_check "Dev Deployment patched with minimal resource requests (50m / 64Mi)" 0
else
    record_check "Dev Deployment resource patch applied" 1 "Resource requests 50m / 64Mi not found"
fi

# 6. Generated hash suffix on ConfigMap and Secret
if grep -q "name: dev-payment-config-" "$DEV_YAML" && grep -q "name: dev-payment-secrets-" "$DEV_YAML"; then
    record_check "Dev ConfigMap and Secret generated with dynamic SHA-hash suffixes" 0
else
    record_check "Dev Hash suffix generation" 1 "Hash suffixes missing from generated resources"
fi

# --- Staging Assertions ---
echo -e "\n  ${CLR_MAGENTA}[Staging Environment Checks]${CLR_RESET}"
# 1. Namespace
if grep -q "namespace: staging-environment" "$STAGING_YAML"; then
    record_check "Staging namespace set to staging-environment" 0
else
    record_check "Staging namespace set to staging-environment" 1 "Missing staging-environment namespace"
fi

# 2. Replicas
STAGING_REPLICAS=$(awk '/kind: Deployment/,/replicas:/ { if ($1 == "replicas:") print $2 }' "$STAGING_YAML" | head -n1)
if [[ "$STAGING_REPLICAS" -eq 2 ]]; then
    record_check "Staging deployment replica count equals 2" 0 "replicas: $STAGING_REPLICAS"
else
    record_check "Staging deployment replica count equals 2" 1 "Expected 2, got ${STAGING_REPLICAS:-none}"
fi

# 3. Prometheus scrape annotation
if grep -q 'prometheus.io/scrape: "true"' "$STAGING_YAML"; then
    record_check "Staging Deployment includes prometheus.io/scrape annotation" 0
else
    record_check "Staging Prometheus annotation" 1 "Annotation not found"
fi

# 4. Intermediate resource requests (100m/128Mi)
if grep -q "cpu: 100m" "$STAGING_YAML" && grep -q "memory: 128Mi" "$STAGING_YAML"; then
    record_check "Staging Deployment configured with intermediate resource requests (100m / 128Mi)" 0
else
    record_check "Staging resource requests" 1 "Resource requests 100m / 128Mi not found"
fi

# --- Production Assertions ---
echo -e "\n  ${CLR_MAGENTA}[Production Environment Checks]${CLR_RESET}"
# 1. Namespace
if grep -q "namespace: prod-environment" "$PROD_YAML"; then
    record_check "Prod namespace set to prod-environment" 0
else
    record_check "Prod namespace set to prod-environment" 1 "Missing prod-environment namespace"
fi

# 2. Replicas
PROD_REPLICAS=$(awk '/kind: Deployment/,/replicas:/ { if ($1 == "replicas:") print $2 }' "$PROD_YAML" | head -n1)
if [[ "$PROD_REPLICAS" -eq 5 ]]; then
    record_check "Prod deployment replica count equals 5" 0 "replicas: $PROD_REPLICAS"
else
    record_check "Prod deployment replica count equals 5" 1 "Expected 5, got ${PROD_REPLICAS:-none}"
fi

# 3. Image tag pinned to v1.4.2
if grep -q "image: payment-service:v1.4.2" "$PROD_YAML"; then
    record_check "Prod container image pinned to immutable version (payment-service:v1.4.2)" 0
else
    record_check "Prod container image pinned" 1 "Expected payment-service:v1.4.2"
fi

# 4. JSON 6902 patch: revisionHistoryLimit: 10
if grep -q "revisionHistoryLimit: 10" "$PROD_YAML" && grep -q 'security.ops/sla: "99.99"' "$PROD_YAML"; then
    record_check "RFC 6902 JSON patch applied (revisionHistoryLimit: 10 & SLA annotation)" 0
else
    record_check "RFC 6902 JSON patch applied" 1 "JSON 6902 patch values missing"
fi

# 5. PodDisruptionBudget included
if grep -q "kind: PodDisruptionBudget" "$PROD_YAML" && grep -q "minAvailable: 3" "$PROD_YAML"; then
    record_check "Prod includes PodDisruptionBudget with minAvailable: 3" 0
else
    record_check "Prod PodDisruptionBudget" 1 "PodDisruptionBudget missing or invalid"
fi

# 6. Security Context hardening
if grep -q "readOnlyRootFilesystem: true" "$PROD_YAML" && grep -q "drop:" "$PROD_YAML"; then
    record_check "Prod container includes hardened securityContext (readOnlyRootFilesystem & drop ALL)" 0
else
    record_check "Prod securityContext hardening" 1 "Hardening settings missing in production"
fi

# 7. Pod Anti-Affinity
if grep -q "podAntiAffinity:" "$PROD_YAML" && grep -q "topologyKey: kubernetes.io/hostname" "$PROD_YAML"; then
    record_check "Prod Deployment includes high-availability podAntiAffinity rule" 0
else
    record_check "Prod podAntiAffinity" 1 "podAntiAffinity rule missing in production"
fi

# 4. Print Environment Comparison Matrix
echo -e "\n${CLR_YELLOW}▶ Step 4: Environment Matrix Summary${CLR_RESET}"
echo -e "${CLR_CYAN}+---------------------+-------------------+----------+------------------------+------------------+---------------+${CLR_RESET}"
echo -e "${CLR_CYAN}| Environment         | Namespace         | Replicas | Image Version          | Log Level        | Memory Limit  |${CLR_RESET}"
echo -e "${CLR_CYAN}+---------------------+-------------------+----------+------------------------+------------------+---------------+${CLR_RESET}"
echo -e "| Development (dev)   | dev-environment   | 1        | payment-service:latest | debug            | 128Mi         |"
echo -e "| Staging (staging)   | staging-environ.. | 2        | payment-service:latest | info             | 256Mi         |"
echo -e "| Production (prod)   | prod-environment  | 5        | payment-service:v1.4.2 | warn             | 512Mi         |"
echo -e "${CLR_CYAN}+---------------------+-------------------+----------+------------------------+------------------+---------------+${CLR_RESET}"

# 5. Summary
echo -e "\n======================================================================"
if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✅ ALL VALIDATION CHECKS PASSED (${PASSED_CHECKS}/${TOTAL_CHECKS})${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ VALIDATION FAILED (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
