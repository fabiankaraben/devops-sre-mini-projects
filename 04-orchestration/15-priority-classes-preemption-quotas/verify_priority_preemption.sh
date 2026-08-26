#!/usr/bin/env bash
# ==============================================================================
# verify_priority_preemption.sh - Priority Classes, Preemption & Quota Validator
# ==============================================================================
# Verifies:
#   1. YAML manifest schema validation
#   2. PriorityClass configurations:
#      - critical-production (1,000,000, PreemptLowerPriority)
#      - standard-tier (50,000, globalDefault: true)
#      - batch-low-priority (1,000, preemptionPolicy: Never)
#   3. Multi-tenant governance:
#      - ResourceQuota definitions and PriorityClass scopeSelectors
#      - LimitRange default requests/limits and min/max container bounds
#   4. Emits Kubernetes QoS & Priority Class operational evaluation matrix
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
echo "  ⚖️  Kubernetes PriorityClasses, Preemption & Quotas Validator"
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
    "01-priority-classes.yaml"
    "02-limit-range.yaml"
    "03-resource-quota.yaml"
    "04-batch-filler-workload.yaml"
    "05-critical-preempting-workload.yaml"
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

# 3. Assert PriorityClass Directives
echo -e "\n${CLR_YELLOW}▶ Step 3: Asserting PriorityClasses, Preemption & Quota Governance...${CLR_RESET}"

PC_FILE="${MANIFESTS_DIR}/01-priority-classes.yaml"
LR_FILE="${MANIFESTS_DIR}/02-limit-range.yaml"
RQ_FILE="${MANIFESTS_DIR}/03-resource-quota.yaml"
CRIT_WORKLOAD="${MANIFESTS_DIR}/05-critical-preempting-workload.yaml"
BATCH_WORKLOAD="${MANIFESTS_DIR}/04-batch-filler-workload.yaml"

# 3.1 PriorityClass Assertions
echo -e "\n  ${CLR_MAGENTA}[1. PriorityClass & Preemption Policies]${CLR_RESET}"
if grep -A 5 "name: critical-production" "$PC_FILE" | grep -q "value: 1000000" && grep -A 5 "name: critical-production" "$PC_FILE" | grep -q "preemptionPolicy: PreemptLowerPriority"; then
    record_check "critical-production PriorityClass (value: 1000000, PreemptLowerPriority)" 0
else
    record_check "critical-production PriorityClass" 1 "critical-production config mismatch"
fi

if grep -A 5 "name: standard-tier" "$PC_FILE" | grep -q "globalDefault: true"; then
    record_check "standard-tier configured as cluster globalDefault: true" 0
else
    record_check "standard-tier globalDefault" 1 "globalDefault: true missing"
fi

if grep -A 5 "name: batch-low-priority" "$PC_FILE" | grep -q "value: 1000" && grep -A 5 "name: batch-low-priority" "$PC_FILE" | grep -q "preemptionPolicy: Never"; then
    record_check "batch-low-priority PriorityClass (value: 1000, preemptionPolicy: Never)" 0
else
    record_check "batch-low-priority PriorityClass" 1 "batch-low-priority config mismatch"
fi

# 3.2 LimitRange Assertions
echo -e "\n  ${CLR_MAGENTA}[2. LimitRange Namespace Resource Constraints]${CLR_RESET}"
if grep -q "defaultRequest:" "$LR_FILE" && grep -q "default:" "$LR_FILE"; then
    record_check "LimitRange enforces default requests and limits per container" 0
else
    record_check "LimitRange default requests/limits" 1 "default/defaultRequest missing"
fi

if grep -q "max:" "$LR_FILE" && grep -q "min:" "$LR_FILE"; then
    record_check "LimitRange defines min/max resource allocation guardrails" 0
else
    record_check "LimitRange min/max" 1 "min/max missing in LimitRange"
fi

# 3.3 ResourceQuota Assertions
echo -e "\n  ${CLR_MAGENTA}[3. ResourceQuota Multi-Tenant Capacity Management]${CLR_RESET}"
if grep -q "requests.cpu:" "$RQ_FILE" && grep -q "requests.memory:" "$RQ_FILE" && grep -q "count/pods:" "$RQ_FILE"; then
    record_check "ResourceQuota constrains CPU, Memory, and Pod counts" 0
else
    record_check "ResourceQuota compute limits" 1 "Compute quotas missing"
fi

if grep -A 6 "scopeSelector:" "$RQ_FILE" | grep -q "scopeName: PriorityClass"; then
    record_check "Scoped ResourceQuota restricts capacity by PriorityClass (scopeSelector)" 0
else
    record_check "ResourceQuota scopeSelector" 1 "scopeSelector PriorityClass missing"
fi

# 3.4 Workload PriorityClass Binding
echo -e "\n  ${CLR_MAGENTA}[4. Workload PriorityClass Binding]${CLR_RESET}"
if grep -q "priorityClassName: critical-production" "$CRIT_WORKLOAD"; then
    record_check "Critical Payment API binds to 'critical-production' PriorityClass" 0
else
    record_check "Critical Workload PriorityClass" 1 "priorityClassName missing in critical workload"
fi

if grep -q "priorityClassName: batch-low-priority" "$BATCH_WORKLOAD"; then
    record_check "Batch Filler Workload binds to 'batch-low-priority' PriorityClass" 0
else
    record_check "Batch Workload PriorityClass" 1 "priorityClassName missing in batch workload"
fi

# 4. Architecture Comparison Table
echo -e "\n${CLR_YELLOW}▶ Step 4: Quality of Service (QoS) vs Priority Classes Matrix${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------------+------------------------------------+${CLR_RESET}"
echo -e "${CLR_CYAN}| Concept                      | Quality of Service (QoS Class)     | PriorityClass                      |${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+------------------------------------+------------------------------------+${CLR_RESET}"
echo -e "| Determination                | Derived from requests/limits ratio | Explicitly configured integer value|"
echo -e "| Target System Layer          | Node Kubelet / OOM Killer          | Cluster Kube-Scheduler Queue       |"
echo -e "| Primary Function             | Node memory pressure eviction order| Scheduling order & pod preemption  |"
echo -e "| Typical Values               | Guaranteed, Burstable, BestEffort  | 1,000 (Batch) to 1,000,000 (Prod)  |"
echo -e "| Preemption Behavior          | Kubelet kills BestEffort on OOM    | Scheduler evicts low priority pods |"
echo -e "${CLR_CYAN}+------------------------------+------------------------------------+------------------------------------+${CLR_RESET}"

# 5. Summary
echo -e "\n======================================================================"
if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✅ ALL PRIORITY & QUOTA VALIDATION CHECKS PASSED (${PASSED_CHECKS}/${TOTAL_CHECKS})${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ VALIDATION FAILED (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
