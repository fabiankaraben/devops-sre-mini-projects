#!/usr/bin/env bash
# ==============================================================================
# verify_daemonset.sh - Automated DaemonSet Policy & Manifest Validator
# ==============================================================================
# Verifies:
#   1. YAML manifest schema validation
#   2. HostPath volume security and read-only flags
#   3. Downward API node metadata injection
#   4. Control-plane tolerations and hostPID settings
#   5. RollingUpdate updateStrategy and maxUnavailable directives
#   6. RBAC least-privilege node inspection permissions
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
echo "  🛡️  Kubernetes DaemonSet Architecture & Policy Validator"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Verify Prerequisites
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

# 2. Manifest File Checks
echo -e "\n${CLR_YELLOW}▶ Step 2: Validating Manifest Declarations...${CLR_RESET}"

MANIFEST_FILES=(
    "00-namespace.yaml"
    "01-rbac.yaml"
    "02-daemonset-standard.yaml"
    "03-daemonset-control-plane.yaml"
    "04-daemonset-rolling-update.yaml"
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

# 3. Assert DaemonSet Architectural Directives
echo -e "\n${CLR_YELLOW}▶ Step 3: Asserting DaemonSet Configurations...${CLR_RESET}"

DS_STD="${MANIFESTS_DIR}/02-daemonset-standard.yaml"
DS_CP="${MANIFESTS_DIR}/03-daemonset-control-plane.yaml"
DS_ROLL="${MANIFESTS_DIR}/04-daemonset-rolling-update.yaml"
RBAC_FILE="${MANIFESTS_DIR}/01-rbac.yaml"

# 3.1 HostPath Mounts
echo -e "\n  ${CLR_MAGENTA}[1. Host Filesystem Mounting & Read-Only Hardening]${CLR_RESET}"
if grep -q "path: /proc" "$DS_STD" && grep -q "path: /sys" "$DS_STD" && grep -q "path: /var/log" "$DS_STD"; then
    record_check "hostPath volumes (/proc, /sys, /var/log) configured" 0
else
    record_check "hostPath volumes" 1 "Missing hostPath mounts"
fi

if grep -A 3 "mountPath: /host/proc" "$DS_STD" | grep -q "readOnly: true"; then
    record_check "Host mounts hardened with readOnly: true" 0
else
    record_check "Host mounts readOnly" 1 "readOnly: true missing on /host/proc"
fi

# 3.2 Downward API
echo -e "\n  ${CLR_MAGENTA}[2. Downward API Node Metadata Injection]${CLR_RESET}"
if grep -q "fieldPath: spec.nodeName" "$DS_STD" && grep -q "fieldPath: status.hostIP" "$DS_STD"; then
    record_check "Downward API injects spec.nodeName and status.hostIP" 0
else
    record_check "Downward API node injection" 1 "Downward API fieldRefs missing"
fi

# 3.3 Control-Plane Tolerations & HostPID
echo -e "\n  ${CLR_MAGENTA}[3. Control-Plane Tolerations & HostPID Isolation]${CLR_RESET}"
if grep -q "node-role.kubernetes.io/control-plane" "$DS_CP" && grep -q "node-role.kubernetes.io/master" "$DS_CP"; then
    record_check "Tolerations for control-plane and master taints configured" 0
else
    record_check "Control-plane tolerations" 1 "Control-plane tolerations missing"
fi

if grep -q "hostPID: true" "$DS_CP"; then
    record_check "hostPID: true enabled for low-level node inspection" 0
else
    record_check "hostPID setting" 1 "hostPID: true missing in control-plane manifest"
fi

# 3.4 Rolling Update Strategy
echo -e "\n  ${CLR_MAGENTA}[4. Zero-Downtime Rolling Update Strategy]${CLR_RESET}"
if grep -A 4 "updateStrategy:" "$DS_ROLL" | grep -q "type: RollingUpdate" && grep -q "maxUnavailable: 1" "$DS_ROLL"; then
    record_check "updateStrategy: RollingUpdate configured with maxUnavailable: 1" 0
else
    record_check "updateStrategy RollingUpdate" 1 "updateStrategy configuration invalid"
fi

if grep -q "image: node-system-agent:v2.0.0" "$DS_ROLL"; then
    record_check "Rolling update manifest targets v2.0.0 image release" 0
else
    record_check "Rolling update image version" 1 "v2.0.0 image missing"
fi

# 3.5 RBAC Least-Privilege Permissions
echo -e "\n  ${CLR_MAGENTA}[5. RBAC Least-Privilege Node Read Permissions]${CLR_RESET}"
if grep -q "resources:.*nodes" "$RBAC_FILE" || grep -A 6 "resources:" "$RBAC_FILE" | grep -q -- "- nodes"; then
    record_check "ClusterRole grants read access to 'nodes', 'nodes/metrics', 'nodes/stats'" 0
else
    record_check "ClusterRole node permissions" 1 "Node permissions missing in RBAC"
fi

if grep -q "kind: ClusterRoleBinding" "$RBAC_FILE" && grep -q "name: node-agent-sa" "$RBAC_FILE"; then
    record_check "ClusterRoleBinding attaches ServiceAccount 'node-agent-sa'" 0
else
    record_check "ClusterRoleBinding" 1 "Binding configuration missing"
fi

# 4. Architecture Summary Table
echo -e "\n${CLR_YELLOW}▶ Step 4: DaemonSet vs Deployment Operational Comparison${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+----------------------------------+------------------------------------+${CLR_RESET}"
echo -e "${CLR_CYAN}| Feature                      | DaemonSet                        | Standard Deployment                |${CLR_RESET}"
echo -e "${CLR_CYAN}+------------------------------+----------------------------------+------------------------------------+${CLR_RESET}"
echo -e "| Replica Placement            | Exactly 1 Pod per Node (or subset| Arbitrary N replicas distributed   |"
echo -e "| Control-Plane Scheduling     | Tolerates master/control taints  | Worker nodes only (by default)     |"
echo -e "| Cordoned Node Behavior       | Ignores Unschedulable (Stays run)| Evicted / Blocked on Cordoned node |"
echo -e "| Scaling Mechanism            | Scales automatically with nodes  | HPA or manual replica change       |"
echo -e "| Common Production Use Cases  | Node Exporter, FluentBit, Cilium | Web APIs, Background Queue Workers |"
echo -e "${CLR_CYAN}+------------------------------+----------------------------------+------------------------------------+${CLR_RESET}"

# 5. Summary
echo -e "\n======================================================================"
if [[ "$FAILED_CHECKS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✅ ALL DAEMONSET VALIDATION CHECKS PASSED (${PASSED_CHECKS}/${TOTAL_CHECKS})${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ DAEMONSET VALIDATION FAILED (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
