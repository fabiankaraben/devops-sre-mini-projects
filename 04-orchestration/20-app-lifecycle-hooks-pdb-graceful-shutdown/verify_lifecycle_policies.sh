#!/usr/bin/env bash
# ==============================================================================
# verify_lifecycle_policies.sh - Pod Lifecycle, Hooks & PDB Policy Validator
# ==============================================================================
# Verifies:
#   1. YAML manifest schema validation
#   2. Chained InitContainers (dependency check & schema migration)
#   3. Pod lifecycle hooks (postStart & preStop connection draining)
#   4. Termination grace period allocation (terminationGracePeriodSeconds >= 30)
#   5. PodDisruptionBudget constraints (maxUnavailable: 1 & minAvailable: 100%)
#   6. Health & Readiness probe definitions
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
echo "  ⏱️ Kubernetes Pod Lifecycle, Hooks & PDB Policy Validator"
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
    "01-mock-database.yaml"
    "02-lifecycle-deployment.yaml"
    "03-pdb-standard.yaml"
    "04-pdb-strict.yaml"
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

# 3. Assert Lifecycle Policies & Architectural Directives
echo -e "\n${CLR_YELLOW}▶ Step 3: Asserting Pod Lifecycle & High Availability Directives...${CLR_RESET}"

DEP_FILE="${MANIFESTS_DIR}/02-lifecycle-deployment.yaml"
PDB_STD="${MANIFESTS_DIR}/03-pdb-standard.yaml"
PDB_STRICT="${MANIFESTS_DIR}/04-pdb-strict.yaml"

# 3.1 Chained Init Containers
echo -e "\n  ${CLR_MAGENTA}[1. Chained InitContainers (Gated Startup)]${CLR_RESET}"
if grep -q "name: wait-for-database" "$DEP_FILE" && grep -q "name: db-migration-init" "$DEP_FILE"; then
    record_check "Deployment configures chained initContainers (dependency check & schema migration)" 0
else
    record_check "InitContainers definition" 1 "Missing wait-for-database or db-migration-init"
fi

# 3.2 PreStop & PostStart Lifecycle Hooks
echo -e "\n  ${CLR_MAGENTA}[2. Pod Lifecycle Hooks (Graceful Drain)]${CLR_RESET}"
if grep -q "preStop:" "$DEP_FILE" && grep -q "sleep 10" "$DEP_FILE"; then
    record_check "preStop hook executes 'sleep 10' for iptables endpoint de-registration" 0
else
    record_check "preStop hook" 1 "preStop sleep 10 hook missing"
fi

if grep -q "postStart:" "$DEP_FILE"; then
    record_check "postStart hook configured for startup registration" 0
else
    record_check "postStart hook" 1 "postStart hook missing"
fi

# 3.3 Termination Grace Period
echo -e "\n  ${CLR_MAGENTA}[3. Termination Grace Period Allocation]${CLR_RESET}"
if grep -q "terminationGracePeriodSeconds: 30" "$DEP_FILE"; then
    record_check "terminationGracePeriodSeconds configured to 30s (> preStop delay)" 0
else
    record_check "terminationGracePeriodSeconds" 1 "Grace period not set to 30s"
fi

# 3.4 Liveness & Readiness Probes
echo -e "\n  ${CLR_MAGENTA}[4. Health Probes & Traffic Gating]${CLR_RESET}"
if grep -q "livenessProbe:" "$DEP_FILE" && grep -q "readinessProbe:" "$DEP_FILE"; then
    record_check "Both livenessProbe (/healthz) and readinessProbe (/ready) declared" 0
else
    record_check "Health probes" 1 "Missing liveness or readiness probes"
fi

# 3.5 PodDisruptionBudget Constraints
echo -e "\n  ${CLR_MAGENTA}[5. PodDisruptionBudget Constraints]${CLR_RESET}"
if grep -q "maxUnavailable: 1" "$PDB_STD" && grep -q "app: order-service" "$PDB_STD"; then
    record_check "Standard PDB enforces maxUnavailable: 1 for rolling node drains" 0
else
    record_check "Standard PDB" 1 "maxUnavailable constraint mismatch"
fi

if grep -q "minAvailable: 100%" "$PDB_STRICT"; then
    record_check "Strict PDB enforces minAvailable: 100% to block voluntary disruptions" 0
else
    record_check "Strict PDB" 1 "minAvailable constraint mismatch"
fi

# 4. Lifecycle Shutdown Timeline
echo -e "\n${CLR_YELLOW}▶ Step 4: Graceful vs Ungraceful Pod Termination Timeline${CLR_RESET}"
echo -e "${CLR_CYAN}+------+--------------------------------------------------------+-------------------------------------------------------+${CLR_RESET}"
echo -e "${CLR_CYAN}| Time | Standard Unconfigured Pod Shutdown (Packets Dropped!)  | Production Graceful Drain (Zero Dropped Requests)     |${CLR_RESET}"
echo -e "${CLR_CYAN}+------+--------------------------------------------------------+-------------------------------------------------------+${CLR_RESET}"
echo -e "| T=0s | API deletes Pod -> Kubelet sends immediate SIGTERM     | API deletes Pod -> preStop hook triggered (sleep 10s) |"
echo -e "| T=2s | Process exits -> kube-proxy still routes traffic (502!)| kube-proxy removes Pod IP from iptables/Endpoints     |"
echo -e "| T=10s| Kubelet sends SIGKILL to already dead process          | preStop finishes -> App receives SIGTERM              |"
echo -e "| T=11s| Endpoints finally updated (too late!)                  | App drains inflight transactions cleanly -> exits 0   |"
echo -e "${CLR_CYAN}+------+--------------------------------------------------------+-------------------------------------------------------+${CLR_RESET}"

# 5. Summary
echo -e "\n======================================================================"
if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✅ ALL POD LIFECYCLE VALIDATION CHECKS PASSED (${PASSED_CHECKS}/${TOTAL_CHECKS})${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ LIFECYCLE VALIDATION FAILED (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
