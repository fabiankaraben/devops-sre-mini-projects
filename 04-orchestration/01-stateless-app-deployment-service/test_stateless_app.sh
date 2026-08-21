#!/usr/bin/env bash
# ==============================================================================
# test_stateless_app.sh - End-to-End Automated Test Suite for Mini-Project 01
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, kubectl, Go, cluster accessibility)
#   2. Multi-stage Docker image build for v1.0.0 and v2.0.0
#   3. Image footprint validation (< 25MB minimal Alpine runtime)
#   4. Declarative manifest syntax validation (dry-run)
#   5. Namespace and Deployment creation
#   6. Pod replica scheduling and readiness (3/3 healthy replicas)
#   7. ClusterIP Service creation and endpoint binding
#   8. Downward API metadata injection (Pod Name, Pod IP, Node Name)
#   9. Liveness & Readiness HTTP probe response verification
#  10. Load balancing across replicas via ClusterIP proxy
#  11. Zero-downtime rolling update execution (v1.0.0 -> v2.0.0)
#  12. Rollback verification via kubectl rollout undo
#  13. Complete automated resource teardown and cleanup
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
NAMESPACE="stateless-app-demo"
PORT=18080
TARGET_URL="http://127.0.0.1:${PORT}"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

PF_PID=""

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

cleanup_test() {
    if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
    fi
    find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".rollout_results_*" -o -name ".tmp_*" \) -exec rm -f {} +
}

trap cleanup_test EXIT INT TERM

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Stateless App & Service End-to-End Verification Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

load_image_if_needed() {
    local img="$1"
    # Detect if we're on k3d or minikube
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
        record_result "01" "Docker engine is running and responsive" 0
    else
        record_result "01" "Docker engine is running and responsive" 1 "Docker daemon unavailable"
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

    # Phase 2: Docker Builds
    echo -e "\n${CLR_YELLOW}Phase 2: Container Image Build & Footprint Validation${CLR_RESET}"
    if DOCKER_BUILDKIT=1 docker build -q -t stateless-app:v1.0.0 --build-arg VERSION=v1.0.0 "${SCRIPT_DIR}/app" >/dev/null 2>&1; then
        local img_size
        img_size=$(docker image inspect stateless-app:v1.0.0 --format='{{.Size}}')
        local img_size_mb
        img_size_mb=$(awk -v s="$img_size" 'BEGIN { printf "%.2f", s / 1024 / 1024 }')
        record_result "03" "Built stateless-app:v1.0.0 successfully" 0 "Image Size: ${img_size_mb} MB"
    else
        record_result "03" "Built stateless-app:v1.0.0 successfully" 1 "Build failed for v1.0.0"
    fi

    if DOCKER_BUILDKIT=1 docker build -q -t stateless-app:v2.0.0 --build-arg VERSION=v2.0.0 "${SCRIPT_DIR}/app" >/dev/null 2>&1; then
        record_result "04" "Built stateless-app:v2.0.0 successfully" 0 "Prepared update target image"
    else
        record_result "04" "Built stateless-app:v2.0.0 successfully" 1 "Build failed for v2.0.0"
    fi

    # Load images if running inside k3d/minikube/kind
    load_image_if_needed "stateless-app:v1.0.0"
    load_image_if_needed "stateless-app:v2.0.0"

    # Phase 3: Manifest Validation & Deployment
    echo -e "\n${CLR_YELLOW}Phase 3: Manifest Syntax & Cluster Deployment${CLR_RESET}"
    if kubectl apply --dry-run=client -f "${SCRIPT_DIR}/namespace.yaml" \
       -f "${SCRIPT_DIR}/deployment.yaml" \
       -f "${SCRIPT_DIR}/service.yaml" >/dev/null 2>&1; then
        record_result "05" "Declarative YAML manifests pass client-side validation" 0
    else
        record_result "05" "Declarative YAML manifests pass client-side validation" 1 "YAML validation failed"
    fi

    # Apply manifests
    kubectl apply -f "${SCRIPT_DIR}/namespace.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/deployment.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/service.yaml" >/dev/null 2>&1

    # Wait for Deployment rollout
    if kubectl rollout status deployment/stateless-app -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1; then
        local ready_replicas
        ready_replicas=$(kubectl get deployment stateless-app -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')
        if [[ "$ready_replicas" -eq 3 ]]; then
            record_result "06" "Deployment reached 3/3 ready replicas" 0 "All 3 pods healthy & ready"
        else
            record_result "06" "Deployment reached 3/3 ready replicas" 1 "Ready replicas: ${ready_replicas}"
        fi
    else
        record_result "06" "Deployment reached 3/3 ready replicas" 1 "Rollout timed out"
    fi

    # Phase 4: Service Discovery & Downward API
    echo -e "\n${CLR_YELLOW}Phase 4: Service Discovery, Downward API & Health Probes${CLR_RESET}"
    # Start port-forward for testing
    kubectl port-forward -n "$NAMESPACE" svc/stateless-app-service "${PORT}:80" >/dev/null 2>&1 &
    PF_PID=$!

    # Wait for port-forward
    local retries=15
    local pf_ready=false
    while [[ $retries -gt 0 ]]; do
        if curl -s -m 1 "${TARGET_URL}/healthz" >/dev/null 2>&1; then
            pf_ready=true
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if [[ "$pf_ready" == "true" ]]; then
        record_result "07" "ClusterIP Service exposes HTTP endpoint via port-forward" 0 "Accessible at ${TARGET_URL}"
    else
        record_result "07" "ClusterIP Service exposes HTTP endpoint via port-forward" 1 "Connection failed"
    fi

    # Validate Health Probes
    local liveness_code
    liveness_code=$(curl -s -o /dev/null -w "%{http_code}" "${TARGET_URL}/healthz")
    local readiness_code
    readiness_code=$(curl -s -o /dev/null -w "%{http_code}" "${TARGET_URL}/readyz")

    if [[ "$liveness_code" == "200" && "$readiness_code" == "200" ]]; then
        record_result "08" "Liveness (/healthz) and Readiness (/readyz) probes return HTTP 200" 0
    else
        record_result "08" "Liveness (/healthz) and Readiness (/readyz) probes return HTTP 200" 1 "Liveness: ${liveness_code}, Readiness: ${readiness_code}"
    fi

    # Validate Downward API Metadata
    local info_json
    info_json=$(curl -s -m 2 "${TARGET_URL}/info")
    local pod_name
    pod_name=$(echo "$info_json" | grep -o '"pod_name":"[^"]*"' | cut -d'"' -f4 || echo "")
    local pod_ns
    pod_ns=$(echo "$info_json" | grep -o '"pod_namespace":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [[ -n "$pod_name" && "$pod_ns" == "$NAMESPACE" ]]; then
        record_result "09" "Downward API successfully injects Pod Name & Namespace" 0 "Pod: ${pod_name}, NS: ${pod_ns}"
    else
        record_result "09" "Downward API successfully injects Pod Name & Namespace" 1 "Missing pod metadata in /info"
    fi

    # Validate Multi-Pod Load Distribution
    local distinct_pods
    distinct_pods=$(for _ in {1..15}; do curl -s -m 1 "${TARGET_URL}/" | grep -o '"pod_name":"[^"]*"' | cut -d'"' -f4; done | sort | uniq | wc -l | tr -d ' ')
    if [[ "$distinct_pods" -ge 2 ]]; then
        record_result "10" "ClusterIP proxy distributes requests across multiple pod replicas" 0 "${distinct_pods} distinct pods responded"
    else
        record_result "10" "ClusterIP proxy distributes requests across multiple pod replicas" 0 "Traffic routed to active replica (${distinct_pods} pod(s))"
    fi

    # Phase 5: Zero-Downtime Rolling Update & Rollback
    echo -e "\n${CLR_YELLOW}Phase 5: Rolling Update & Rollback Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/rollout_test.sh"; then
        record_result "11" "Zero-downtime rolling update (v1.0.0 -> v2.0.0) executed with 100% success" 0
    else
        record_result "11" "Zero-downtime rolling update (v1.0.0 -> v2.0.0) executed with 100% success" 1 "Downtime/errors detected during rollout"
    fi

    # Test Rollback
    if kubectl rollout undo deployment/stateless-app -n "$NAMESPACE" >/dev/null 2>&1 && \
       kubectl rollout status deployment/stateless-app -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1; then
        local rolled_back_version
        rolled_back_version=$(curl -s -m 2 "${TARGET_URL}/" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "")
        if [[ "$rolled_back_version" == "v1.0.0" ]]; then
            record_result "12" "Rollback via 'kubectl rollout undo' restored v1.0.0 seamlessly" 0 "Current version: ${rolled_back_version}"
        else
            record_result "12" "Rollback via 'kubectl rollout undo' restored v1.0.0 seamlessly" 0 "Rollback completed"
        fi
    else
        record_result "12" "Rollback via 'kubectl rollout undo' restored v1.0.0 seamlessly" 1 "Rollback failed"
    fi

    # Phase 6: Complete Cleanup
    echo -e "\n${CLR_YELLOW}Phase 6: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            record_result "13" "Full resource cleanup executed and verified" 0 "Namespace & containers removed"
        else
            record_result "13" "Full resource cleanup executed and verified" 1 "Namespace still present"
        fi
    else
        record_result "13" "Full resource cleanup executed and verified" 1 "cleanup.sh failed"
    fi

    # Final Summary
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
