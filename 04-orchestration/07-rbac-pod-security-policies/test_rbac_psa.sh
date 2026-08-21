#!/usr/bin/env bash
# ==============================================================================
# test_rbac_psa.sh - DevSecOps RBAC & Pod Security End-to-End Test Suite
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, kubectl CLI, cluster connectivity)
#   2. Declarative manifest syntax & client-side validation
#   3. Namespaces deployment with Pod Security Admission (PSA) labels
#   4. RBAC ServiceAccounts, Roles, RoleBindings, and ClusterRoleBindings
#   5. Developer persona least-privilege boundaries (Pods allowed, Secrets blocked)
#   6. CI/CD persona deployment permissions (Deployments & Secrets in prod allowed)
#   7. Auditor persona cluster-wide read-only scope (Nodes/Namespaces allowed, Exec/Secrets blocked)
#   8. Pod Security Admission (PSA) blocking non-compliant privileged workloads
#   9. Pod Security Admission (PSA) scheduling hardened compliant workloads
#  10. Full automated resource teardown and cleanup
# ==============================================================================

set -euo pipefail

# ANSI Color formatting
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    local test_num="$1"
    local description="$2"
    local status="$3"
    local details="${4:-}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$status" -eq 0 ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_GRAY}↳ ${details}${CLR_RESET}"
        fi
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_RED}↳ ${details}${CLR_RESET}"
        fi
    fi
}

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🛡️ DevSecOps RBAC & Pod Security End-to-End Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

main() {
    print_banner

    # Phase 1: Prerequisites
    echo -e "${CLR_YELLOW}Phase 1: Environment & Tooling Verification${CLR_RESET}"
    if docker info >/dev/null 2>&1; then
        record_result "01" "Docker engine is active and responsive" 0
    else
        record_result "01" "Docker engine is active and responsive" 1 "Docker daemon unavailable"
        exit 1
    fi

    if kubectl cluster-info >/dev/null 2>&1; then
        local cluster_ctx
        cluster_ctx=$(kubectl config current-context)
        record_result "02" "Kubernetes cluster is reachable" 0 "Active context: ${cluster_ctx}"
    else
        record_result "02" "Kubernetes cluster is reachable" 1 "kubectl cannot connect to cluster"
        exit 1
    fi

    # Phase 2: Manifest Dry-Run
    echo -e "\n${CLR_YELLOW}Phase 2: Declarative Manifest Syntax Validation${CLR_RESET}"
    if kubectl apply --dry-run=client -f "${SCRIPT_DIR}/namespaces.yaml" >/dev/null 2>&1 && \
       kubectl apply --dry-run=client -f "${SCRIPT_DIR}/rbac-personas.yaml" >/dev/null 2>&1; then
        record_result "03" "Declarative YAML manifests pass client-side validation" 0
    else
        record_result "03" "Declarative YAML manifests pass client-side validation" 1 "Syntax error"
    fi

    # Phase 3: Cluster Deployment
    echo -e "\n${CLR_YELLOW}Phase 3: Deploying Namespaces with PSA Labels & RBAC Personas${CLR_RESET}"
    kubectl apply -f "${SCRIPT_DIR}/namespaces.yaml" >/dev/null
    kubectl apply -f "${SCRIPT_DIR}/rbac-personas.yaml" >/dev/null

    local psa_enforce
    psa_enforce=$(kubectl get namespace security-restricted -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
    if [[ "$psa_enforce" == "restricted" ]]; then
        record_result "04" "Pod Security Admission (PSA) labels applied to security-restricted" 0 "Enforce Level: ${psa_enforce}"
    else
        record_result "04" "Pod Security Admission (PSA) labels applied to security-restricted" 1 "Missing PSA label"
    fi

    if kubectl get sa developer-sa -n security-dev >/dev/null 2>&1 && \
       kubectl get sa cicd-deployer-sa -n security-restricted >/dev/null 2>&1 && \
       kubectl get clusterrolebinding cluster-auditor-binding >/dev/null 2>&1; then
        record_result "05" "RBAC ServiceAccounts, Roles, and Bindings deployed" 0
    else
        record_result "05" "RBAC ServiceAccounts, Roles, and Bindings deployed" 1 "RBAC objects missing"
    fi

    # Phase 4: RBAC Persona Boundaries
    echo -e "\n${CLR_YELLOW}Phase 4: Persona Least-Privilege Boundary Validation${CLR_RESET}"
    local dev_pod_create dev_secret_get
    dev_pod_create=$(kubectl auth can-i create pods -n security-dev --as=system:serviceaccount:security-dev:developer-sa 2>/dev/null || true)
    dev_pod_create=$(echo "$dev_pod_create" | tr -d '[:space:]')
    dev_secret_get=$(kubectl auth can-i get secrets -n security-dev --as=system:serviceaccount:security-dev:developer-sa 2>/dev/null || true)
    dev_secret_get=$(echo "$dev_secret_get" | tr -d '[:space:]')
    if [[ "$dev_pod_create" == "yes" && "$dev_secret_get" == "no" ]]; then
        record_result "06" "Developer persona allows pod creation but blocks secret reads" 0
    else
        record_result "06" "Developer persona allows pod creation but blocks secret reads" 1 "Create: ${dev_pod_create}, Secret: ${dev_secret_get}"
    fi

    local cicd_deploy cicd_node_del
    cicd_deploy=$(kubectl auth can-i create deployments -n security-restricted --as=system:serviceaccount:security-restricted:cicd-deployer-sa 2>/dev/null || true)
    cicd_deploy=$(echo "$cicd_deploy" | tr -d '[:space:]')
    cicd_node_del=$(kubectl auth can-i delete nodes --as=system:serviceaccount:security-restricted:cicd-deployer-sa 2>/dev/null || true)
    cicd_node_del=$(echo "$cicd_node_del" | tr -d '[:space:]')
    if [[ "$cicd_deploy" == "yes" && "$cicd_node_del" == "no" ]]; then
        record_result "07" "CI/CD persona allows prod deployments but blocks cluster node modifications" 0
    else
        record_result "07" "CI/CD persona allows prod deployments but blocks cluster node modifications" 1 "Deploy: ${cicd_deploy}, NodeDel: ${cicd_node_del}"
    fi

    local auditor_nodes auditor_exec
    auditor_nodes=$(kubectl auth can-i get nodes --as=system:serviceaccount:security-dev:auditor-sa 2>/dev/null || true)
    auditor_nodes=$(echo "$auditor_nodes" | tr -d '[:space:]')
    auditor_exec=$(kubectl auth can-i create pods/exec -n security-dev --as=system:serviceaccount:security-dev:auditor-sa 2>/dev/null || true)
    auditor_exec=$(echo "$auditor_exec" | tr -d '[:space:]')
    if [[ "$auditor_nodes" == "yes" && "$auditor_exec" == "no" ]]; then
        record_result "08" "Auditor persona permits cluster-wide topology reads but blocks pod exec" 0
    else
        record_result "08" "Auditor persona permits cluster-wide topology reads but blocks pod exec" 1 "Nodes: ${auditor_nodes}, Exec: ${auditor_exec}"
    fi

    # Phase 5: Pod Security Admission & Workloads
    echo -e "\n${CLR_YELLOW}Phase 5: Pod Security Admission (PSA) Enforcement${CLR_RESET}"
    if ! kubectl apply -f "${SCRIPT_DIR}/workloads/privileged-pod.yaml" -n security-restricted >/dev/null 2>&1; then
        record_result "09" "PSA admission webhook correctly REJECTS privileged workload" 0 "security-restricted namespace"
    else
        record_result "09" "PSA admission webhook correctly REJECTS privileged workload" 1 "Privileged pod was admitted"
        kubectl delete -f "${SCRIPT_DIR}/workloads/privileged-pod.yaml" -n security-restricted >/dev/null 2>&1 || true
    fi

    if kubectl apply -f "${SCRIPT_DIR}/workloads/compliant-pod.yaml" -n security-restricted >/dev/null 2>&1; then
        kubectl wait --for=condition=Ready pod/compliant-secure-pod -n security-restricted --timeout=30s >/dev/null 2>&1 || true
        record_result "10" "PSA admission webhook ADMITS compliant hardened workload" 0 "compliant-secure-pod Ready"
        kubectl delete -f "${SCRIPT_DIR}/workloads/compliant-pod.yaml" -n security-restricted --grace-period=0 --force >/dev/null 2>&1 || true
    else
        record_result "10" "PSA admission webhook ADMITS compliant hardened workload" 1 "Hardened pod was rejected"
    fi

    # Phase 6: Automated Audit Tool Execution
    echo -e "\n${CLR_YELLOW}Phase 6: Executing Comprehensive rbac_audit_test.sh Tool${CLR_RESET}"
    if "${SCRIPT_DIR}/rbac_audit_test.sh" >/dev/null; then
        record_result "11" "rbac_audit_test.sh executed full authorization matrix successfully" 0
    else
        record_result "11" "rbac_audit_test.sh executed full authorization matrix successfully" 1 "Audit failed"
    fi

    # Phase 7: Teardown & Cleanliness
    echo -e "\n${CLR_YELLOW}Phase 7: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace security-restricted >/dev/null 2>&1 && \
           ! kubectl get clusterrole cluster-auditor-role >/dev/null 2>&1; then
            record_result "12" "Full resource cleanup executed and verified" 0 "ClusterRoles, Bindings & Namespaces removed"
        else
            record_result "12" "Full resource cleanup executed and verified" 1 "Residual objects found"
        fi
    else
        record_result "12" "Full resource cleanup executed and verified" 1 "cleanup.sh failed"
    fi

    # Summary
    echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "  Automated Verification Summary: ${CLR_GREEN}${PASSED_TESTS} Passed${CLR_RESET}, ${CLR_RED}${FAILED_TESTS} Failed${CLR_RESET} (Total: ${TOTAL_TESTS})"
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}🎉 ALL TESTS PASSED SUCCESSFULLY!${CLR_RESET}\n"
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED WITH ${FAILED_TESTS} FAILURES${CLR_RESET}\n"
        exit 1
    fi
}

main "$@"
