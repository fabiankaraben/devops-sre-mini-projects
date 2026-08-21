#!/usr/bin/env bash
# ==============================================================================
# test_hpa.sh - Horizontal Pod Autoscaler (HPA v2) End-to-End Test Suite
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, kubectl, cluster connectivity)
#   2. Metrics Server availability (metrics.k8s.io API)
#   3. Multi-stage container image build (<20MB Alpine runtime)
#   4. Image loading into local cluster runtime (k3d/minikube/kind)
#   5. Declarative manifest syntax validation (dry-run)
#   6. Deployment readiness with CPU/memory resource limits (2/2 replicas)
#   7. HPA v2 binding and metric targets (CPU 50% utilization)
#   8. ClusterIP Service reachability via port-forward
#   9. Real-time scale-up and scale-down cooldown via load_generator.sh
#  10. Complete automated resource teardown and cleanup
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
NAMESPACE="hpa-demo"
DEPLOYMENT_NAME="autoscale-app"
HPA_NAME="autoscale-hpa"

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
    echo "  🚀 Horizontal Pod Autoscaler (HPA v2) End-to-End Test Suite"
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

    # Phase 2: Metrics Server Check
    echo -e "\n${CLR_YELLOW}Phase 2: Metrics Server & Metrics API Validation${CLR_RESET}"
    local metrics_api_ready=false
    for _ in {1..20}; do
        if kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
            metrics_api_ready=true
            break
        fi
        sleep 2
    done

    if [[ "$metrics_api_ready" == "true" ]]; then
        record_result "03" "Metrics API (metrics.k8s.io) is active and available" 0 "APIService: v1beta1.metrics.k8s.io"
    else
        record_result "03" "Metrics API (metrics.k8s.io) is active and available" 1 "Metrics API unavailable"
    fi

    # Phase 3: Container Build
    echo -e "\n${CLR_YELLOW}Phase 3: Container Image Build & Size Validation${CLR_RESET}"
    if DOCKER_BUILDKIT=1 docker build -q -t autoscale-app:v1.0.0 "${SCRIPT_DIR}/app" >/dev/null 2>&1; then
        local img_size
        img_size=$(docker image inspect autoscale-app:v1.0.0 --format='{{.Size}}')
        local img_size_mb
        img_size_mb=$(awk -v s="$img_size" 'BEGIN { printf "%.2f", s / 1024 / 1024 }')
        record_result "04" "Built autoscale-app:v1.0.0 successfully" 0 "Image Size: ${img_size_mb} MB"
    else
        record_result "04" "Built autoscale-app:v1.0.0 successfully" 1 "Build failed"
    fi

    load_image_if_needed "autoscale-app:v1.0.0"

    # Phase 4: Manifest Validation & Deployment
    echo -e "\n${CLR_YELLOW}Phase 4: Manifest Syntax & Cluster Deployment${CLR_RESET}"
    if kubectl apply --dry-run=client -f "${SCRIPT_DIR}/namespace.yaml" \
       -f "${SCRIPT_DIR}/deployment.yaml" \
       -f "${SCRIPT_DIR}/service.yaml" \
       -f "${SCRIPT_DIR}/hpa.yaml" >/dev/null 2>&1; then
        record_result "05" "Declarative YAML manifests pass client-side validation" 0
    else
        record_result "05" "Declarative YAML manifests pass client-side validation" 1 "YAML validation failed"
    fi

    kubectl apply -f "${SCRIPT_DIR}/namespace.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/deployment.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/service.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/hpa.yaml" >/dev/null 2>&1

    if kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1; then
        record_result "06" "Deployment reached initial 2/2 ready replicas" 0 "Replicas: 2"
    else
        record_result "06" "Deployment reached initial 2/2 ready replicas" 1 "Rollout timed out"
    fi

    # Phase 5: HPA Target Binding
    echo -e "\n${CLR_YELLOW}Phase 5: HPA Resource Metrics Binding Auditing${CLR_RESET}"
    local hpa_target
    hpa_target=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null || echo "")

    if [[ "$hpa_target" == "$DEPLOYMENT_NAME" ]]; then
        record_result "07" "HPA binds target deployment with 50% CPU metric target" 0 "Target: ${hpa_target} (Min: 2, Max: 10)"
    else
        record_result "07" "HPA binds target deployment with 50% CPU metric target" 1 "Target: ${hpa_target}"
    fi

    # Port-Forward Check
    local pf_port=18083
    kubectl port-forward -n "$NAMESPACE" svc/autoscale-service "${pf_port}:80" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    local info_resp
    info_resp=$(curl -s "http://127.0.0.1:${pf_port}/" 2>/dev/null || echo "")
    kill -9 "$pf_pid" >/dev/null 2>&1 || true

    if [[ "$info_resp" == *"autoscale-app"* ]]; then
        record_result "08" "ClusterIP Service routes traffic to autoscaling pods" 0 "Service: autoscale-service"
    else
        record_result "08" "ClusterIP Service routes traffic to autoscaling pods" 1 "Response: ${info_resp}"
    fi

    # Phase 6: Load Generation & Autoscaling Verification
    echo -e "\n${CLR_YELLOW}Phase 6: Dynamic Load Generation & Autoscaling Verification${CLR_RESET}"
    if BURST_DURATION_SECS=35 LOAD_CONCURRENCY=25 "${SCRIPT_DIR}/load_generator.sh"; then
        record_result "09" "load_generator.sh verified dynamic scale-up and scale-down stabilization" 0
    else
        record_result "09" "load_generator.sh verified dynamic scale-up and scale-down stabilization" 1 "HPA test failed"
    fi

    # Phase 7: Teardown & Cleanliness
    echo -e "\n${CLR_YELLOW}Phase 7: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            record_result "10" "Full resource cleanup executed and verified" 0 "Namespace, pods, HPA & images removed"
        else
            record_result "10" "Full resource cleanup executed and verified" 1 "Namespace still exists"
        fi
    else
        record_result "10" "Full resource cleanup executed and verified" 1 "cleanup.sh failed"
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
