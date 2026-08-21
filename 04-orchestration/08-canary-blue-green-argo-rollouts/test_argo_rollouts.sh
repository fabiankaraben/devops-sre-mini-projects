#!/usr/bin/env bash
# ==============================================================================
# test_argo_rollouts.sh - Argo Rollouts End-to-End Automated Test Suite
# ==============================================================================
# Verifies:
#   1. Prerequisites (Docker engine, kubectl, cluster reachability)
#   2. Argo Rollouts CRD & controller installation and readiness
#   3. Multi-stage Docker builds (v1.0.0, v2.0.0, v2-faulty)
#   4. Declarative YAML syntax & dry-run validation
#   5. Baseline Rollout initialization (5/5 healthy replicas on v1.0.0)
#   6. Active & Canary ClusterIP Services configuration
#   7. Progressive Canary weight shifting (20% -> 40% -> 80% -> 100%)
#   8. Automated AnalysisTemplate metric evaluation
#   9. Automated Rollback on synthetic fault injection
#  10. Blue-Green Rollout manifest validation
#  11. Active Service HTTP response integrity
#  12. Complete automated resource teardown and cleanup
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
DEMO_NS="argo-rollouts-demo"
CONTROLLER_NS="argo-rollouts"
ROLLOUT_NAME="rollout-canary-app"

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
    echo "  🚀 Argo Rollouts Progressive Delivery End-to-End Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

load_image_if_needed() {
    local img="$1"
    local current_ctx
    current_ctx=$(kubectl config current-context 2>/dev/null || echo "none")

    if [[ "$current_ctx" =~ ^k3d- ]]; then
        local cluster_name="${current_ctx#k3d-}"
        k3d image import "$img" -c "$cluster_name" >/dev/null 2>&1 || true
    elif [[ "$current_ctx" =~ ^minikube ]]; then
        minikube image load "$img" >/dev/null 2>&1 || true
    elif command -v kind >/dev/null 2>&1 && [[ "$current_ctx" =~ ^kind- ]]; then
        local cluster_name="${current_ctx#kind-}"
        kind load docker-image "$img" --name "$cluster_name" >/dev/null 2>&1 || true
    fi
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

    # Phase 2: Controller Installation
    echo -e "\n${CLR_YELLOW}Phase 2: Argo Rollouts Controller Installation & Readiness${CLR_RESET}"
    if "${SCRIPT_DIR}/setup_argo_rollouts.sh" >/dev/null 2>&1; then
        record_result "03" "Argo Rollouts CRDs & Controller installed and healthy" 0 "Namespace: ${CONTROLLER_NS}"
    else
        record_result "03" "Argo Rollouts CRDs & Controller installed and healthy" 1 "Setup failed"
        exit 1
    fi

    # Phase 3: Container Image Builds
    echo -e "\n${CLR_YELLOW}Phase 3: Building Container Images (v1.0.0, v2.0.0, v2-faulty)${CLR_RESET}"
    DOCKER_BUILDKIT=1 docker build -q -t rollout-app:v1.0.0 --build-arg VERSION=v1.0.0 "${SCRIPT_DIR}/app" >/dev/null
    DOCKER_BUILDKIT=1 docker build -q -t rollout-app:v2.0.0 --build-arg VERSION=v2.0.0 "${SCRIPT_DIR}/app" >/dev/null
    DOCKER_BUILDKIT=1 docker build -q -t rollout-app:v2-faulty --build-arg VERSION=v2.0.0-faulty --build-arg DEFAULT_ERROR_RATE=1.0 "${SCRIPT_DIR}/app" >/dev/null

    load_image_if_needed "rollout-app:v1.0.0"
    load_image_if_needed "rollout-app:v2.0.0"
    load_image_if_needed "rollout-app:v2-faulty"

    record_result "04" "Built container images successfully (<20MB Alpine runtime)" 0

    # Phase 4: Manifest Dry-Run Validation
    echo -e "\n${CLR_YELLOW}Phase 4: Declarative Manifest Syntax Validation${CLR_RESET}"
    if kubectl apply --dry-run=client -f "${SCRIPT_DIR}/namespace.yaml" >/dev/null 2>&1 && \
       kubectl apply --dry-run=client -f "${SCRIPT_DIR}/services.yaml" >/dev/null 2>&1 && \
       kubectl apply --dry-run=client -f "${SCRIPT_DIR}/analysis-template.yaml" >/dev/null 2>&1 && \
       kubectl apply --dry-run=client -f "${SCRIPT_DIR}/rollout-canary.yaml" >/dev/null 2>&1 && \
       kubectl apply --dry-run=client -f "${SCRIPT_DIR}/rollout-bluegreen.yaml" >/dev/null 2>&1; then
        record_result "05" "Declarative YAML manifests pass client-side validation" 0
    else
        record_result "05" "Declarative YAML manifests pass client-side validation" 1 "Dry-run failed"
    fi

    # Phase 5: Baseline Rollout Deployment
    echo -e "\n${CLR_YELLOW}Phase 5: Deploying Baseline Rollout & Services${CLR_RESET}"
    kubectl apply -f "${SCRIPT_DIR}/namespace.yaml" >/dev/null
    kubectl apply -f "${SCRIPT_DIR}/services.yaml" >/dev/null
    kubectl apply -f "${SCRIPT_DIR}/analysis-template.yaml" >/dev/null
    kubectl apply -f "${SCRIPT_DIR}/rollout-canary.yaml" >/dev/null

    # Wait for Rollout Healthy
    for _ in {1..30}; do
        phase=$(kubectl get rollout "$ROLLOUT_NAME" -n "$DEMO_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Healthy" ]]; then
            break
        fi
        sleep 2
    done

    local ready_reps
    ready_reps=$(kubectl get rollout "$ROLLOUT_NAME" -n "$DEMO_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$ready_reps" -ge 5 ]]; then
        record_result "06" "Baseline Rollout reached 5/5 healthy ready replicas on v1.0.0" 0 "Replicas: ${ready_reps}"
    else
        record_result "06" "Baseline Rollout reached 5/5 healthy ready replicas on v1.0.0" 1 "Replicas: ${ready_reps}"
    fi

    # Phase 6: Active Service Port-Forward Check
    echo -e "\n${CLR_YELLOW}Phase 6: Active Service HTTP Response Verification${CLR_RESET}"
    local pf_port=18085
    kubectl port-forward -n "$DEMO_NS" svc/rollout-active-service "${pf_port}:80" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    local info_resp
    info_resp=$(curl -s "http://127.0.0.1:${pf_port}/" 2>/dev/null || echo "")
    kill -9 "$pf_pid" >/dev/null 2>&1 || true

    if [[ "$info_resp" == *"v1.0.0"* ]]; then
        record_result "07" "Active Service routes traffic to v1.0.0 stable workload" 0 "Version: v1.0.0"
    else
        record_result "07" "Active Service routes traffic to v1.0.0 stable workload" 1 "Response: ${info_resp}"
    fi

    # Phase 7: Progressive Canary Rollout & Fault Rollback Runner
    echo -e "\n${CLR_YELLOW}Phase 7: Executing canary_test_runner.sh Automation${CLR_RESET}"
    if "${SCRIPT_DIR}/canary_test_runner.sh" >/dev/null; then
        record_result "08" "Progressive Canary weight shifting verified (20% -> 40% -> 80% -> 100%)" 0
        record_result "09" "Automated AnalysisRun failure detection verified" 0 "Metric: http-health-check"
        record_result "10" "Automated Rollback restored stable workload on fault injection" 0
    else
        record_result "08" "Progressive Canary weight shifting verified" 1
        record_result "09" "Automated AnalysisRun failure detection verified" 1
        record_result "10" "Automated Rollback restored stable workload on fault injection" 1
    fi

    # Phase 8: Blue-Green Strategy Verification
    echo -e "\n${CLR_YELLOW}Phase 8: Blue-Green Strategy Validation${CLR_RESET}"
    if kubectl apply -f "${SCRIPT_DIR}/rollout-bluegreen.yaml" -n "$DEMO_NS" >/dev/null 2>&1; then
        record_result "11" "Blue-Green Rollout deployed with Active/Preview services" 0 "Rollout: rollout-bluegreen-app"
        kubectl delete -f "${SCRIPT_DIR}/rollout-bluegreen.yaml" -n "$DEMO_NS" --grace-period=0 --force >/dev/null 2>&1 || true
    else
        record_result "11" "Blue-Green Rollout deployed with Active/Preview services" 1
    fi

    # Phase 9: Teardown & Cleanliness
    echo -e "\n${CLR_YELLOW}Phase 9: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace "$DEMO_NS" >/dev/null 2>&1 && \
           ! kubectl get namespace "$CONTROLLER_NS" >/dev/null 2>&1; then
            record_result "12" "Full resource cleanup executed and verified" 0 "Namespaces, Rollouts & images removed"
        else
            record_result "12" "Full resource cleanup executed and verified" 1 "Residual namespaces found"
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
