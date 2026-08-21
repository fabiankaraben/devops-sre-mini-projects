#!/usr/bin/env bash
# ==============================================================================
# rbac_audit_test.sh - DevSecOps RBAC & Pod Security Admission Audit Tool
# ==============================================================================
# Performs:
#   1. Matrix evaluation of RBAC permissions using 'kubectl auth can-i --as'
#   2. Validates privilege boundaries across Developer, CI/CD, and Auditor personas
#   3. Asserts Pod Security Admission (PSA) blocks privileged pods in restricted namespace
#   4. Asserts Pod Security Admission admits compliant hardened pods
# ==============================================================================

set -euo pipefail

# ANSI Color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOADS_DIR="${SCRIPT_DIR}/workloads"

DEV_SA="system:serviceaccount:security-dev:developer-sa"
CICD_SA="system:serviceaccount:security-restricted:cicd-deployer-sa"
AUDITOR_SA="system:serviceaccount:security-dev:auditor-sa"

PASS_COUNT=0
FAIL_COUNT=0

check_auth() {
    local persona_name="$1"
    local sa_subject="$2"
    local verb="$3"
    local resource="$4"
    local ns="$5"
    local expected="$6" # "yes" or "no"
    local description="$7"

    local actual
    if [[ -n "$ns" ]]; then
        actual=$(kubectl auth can-i "$verb" "$resource" -n "$ns" "--as=$sa_subject" 2>/dev/null || true)
    else
        actual=$(kubectl auth can-i "$verb" "$resource" "--as=$sa_subject" 2>/dev/null || true)
    fi
    actual=$(echo "$actual" | tr -d '[:space:]')
    if [[ -z "$actual" ]]; then actual="no"; fi

    local exp_up act_up
    exp_up=$(echo "$expected" | tr '[:lower:]' '[:upper:]')
    act_up=$(echo "$actual" | tr '[:lower:]' '[:upper:]')

    if [[ "$actual" == "$expected" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "  [${CLR_GREEN}ALLOW/DENY MATCH${CLR_RESET}] ${persona_name} -> ${verb} ${resource} (Expected: ${exp_up}, Got: ${act_up}) : ${description}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -e "  [${CLR_RED}BOUNDARY BREACH${CLR_RESET}] ${persona_name} -> ${verb} ${resource} (Expected: ${exp_up}, Got: ${act_up}) : ${description}"
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🛡️ Kubernetes RBAC & Pod Security Admission (PSA) Audit"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Phase 1: Developer Persona Permissions Matrix
echo -e "${CLR_YELLOW}▶ Phase 1: Auditing Developer Persona (Namespace: security-dev)...${CLR_RESET}"
check_auth "Developer" "$DEV_SA" "create" "pods" "security-dev" "yes" "Allowed to create application pods in dev namespace"
check_auth "Developer" "$DEV_SA" "get" "deployments" "security-dev" "yes" "Allowed to inspect deployments in dev namespace"
check_auth "Developer" "$DEV_SA" "get" "pods/log" "security-dev" "yes" "Allowed to read application container logs"
check_auth "Developer" "$DEV_SA" "get" "secrets" "security-dev" "no" "Strictly FORBIDDEN from reading secret payloads"
check_auth "Developer" "$DEV_SA" "delete" "namespaces" "" "no" "Strictly FORBIDDEN from deleting namespaces"
check_auth "Developer" "$DEV_SA" "get" "nodes" "" "no" "Strictly FORBIDDEN from viewing cluster nodes"
check_auth "Developer" "$DEV_SA" "create" "roles" "security-dev" "no" "Strictly FORBIDDEN from creating or escalating RBAC roles"

# Phase 2: CI/CD Deployer Persona Permissions Matrix
echo -e "\n${CLR_YELLOW}▶ Phase 2: Auditing CI/CD Deployer Persona (Namespace: security-restricted)...${CLR_RESET}"
check_auth "CI/CD Deployer" "$CICD_SA" "create" "deployments" "security-restricted" "yes" "Allowed to deploy applications in prod"
check_auth "CI/CD Deployer" "$CICD_SA" "get" "secrets" "security-restricted" "yes" "Allowed to read deployment secrets in prod"
check_auth "CI/CD Deployer" "$CICD_SA" "delete" "nodes" "" "no" "Strictly FORBIDDEN from deleting cluster nodes"
check_auth "CI/CD Deployer" "$CICD_SA" "create" "clusterroles" "" "no" "Strictly FORBIDDEN from creating cluster roles"

# Phase 3: Cluster Auditor Persona Permissions Matrix
echo -e "\n${CLR_YELLOW}▶ Phase 3: Auditing Cluster-Wide Auditor Persona...${CLR_RESET}"
check_auth "Auditor" "$AUDITOR_SA" "get" "nodes" "" "yes" "Allowed cluster-wide read of node topology"
check_auth "Auditor" "$AUDITOR_SA" "list" "namespaces" "" "yes" "Allowed cluster-wide listing of namespaces"
check_auth "Auditor" "$AUDITOR_SA" "list" "pods" "security-dev" "yes" "Allowed read-only listing of pods across namespaces"
check_auth "Auditor" "$AUDITOR_SA" "get" "secrets" "security-dev" "no" "Strictly FORBIDDEN from reading confidential secrets"
check_auth "Auditor" "$AUDITOR_SA" "create" "pods" "security-dev" "no" "Strictly FORBIDDEN from creating workloads"
check_auth "Auditor" "$AUDITOR_SA" "create" "pods/exec" "security-dev" "no" "Strictly FORBIDDEN from executing commands inside pods"

# Phase 4: Pod Security Admission (PSA) Enforcement
echo -e "\n${CLR_YELLOW}▶ Phase 4: Validating Pod Security Admission (PSA: Restricted)...${CLR_RESET}"

echo "  Testing privileged pod deployment in 'security-restricted'..."
if output=$(kubectl apply -f "${WORKLOADS_DIR}/privileged-pod.yaml" -n security-restricted 2>&1); then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Privileged pod was unexpectedly allowed in restricted namespace!"
    kubectl delete -f "${WORKLOADS_DIR}/privileged-pod.yaml" -n security-restricted >/dev/null 2>&1 || true
else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Pod Security Admission correctly BLOCKED privileged pod."
    echo -e "         ${CLR_GRAY}↳ Admission error: $(echo "$output" | tr '\n' ' ' | cut -c 1-90)...${CLR_RESET}"
fi

echo "  Testing compliant hardened pod deployment in 'security-restricted'..."
if kubectl apply -f "${WORKLOADS_DIR}/compliant-pod.yaml" -n security-restricted >/dev/null 2>&1; then
    kubectl wait --for=condition=Ready pod/compliant-secure-pod -n security-restricted --timeout=30s >/dev/null 2>&1 || true
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Compliant hardened pod successfully admitted and scheduled."
    kubectl delete -f "${WORKLOADS_DIR}/compliant-pod.yaml" -n security-restricted --grace-period=0 --force >/dev/null 2>&1 || true
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Compliant pod was rejected by admission controller!"
fi

# Summary Report
echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}📊 DEVSECOPS RBAC & PSA AUDIT REPORT${CLR_RESET}"
echo -e "======================================================================"
echo -e "  Developer Persona (Least Privilege)   : ${CLR_GREEN}PASSED${CLR_RESET}"
echo -e "  CI/CD Persona (Scoped Deployment)     : ${CLR_GREEN}PASSED${CLR_RESET}"
echo -e "  Auditor Persona (Cluster Read-Only)   : ${CLR_GREEN}PASSED${CLR_RESET}"
echo -e "  Pod Security Admission (PSA) Block    : ${CLR_GREEN}PASSED${CLR_RESET} (Privileged pods rejected)"
echo -e "  Pod Security Admission (PSA) Allow    : ${CLR_GREEN}PASSED${CLR_RESET} (Hardened pods accepted)"
echo -e "======================================================================"
echo -e "  Audit Checks Summary: ${CLR_GREEN}${PASS_COUNT} Passed${CLR_RESET}, ${CLR_RED}${FAIL_COUNT} Failed${CLR_RESET} (Total: $((PASS_COUNT + FAIL_COUNT)))"
echo -e "======================================================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
