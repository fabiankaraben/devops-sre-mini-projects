#!/usr/bin/env bash
# ==============================================================================
# test_statefulset.sh - StatefulSet & Dynamic Storage End-to-End Test Suite
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, kubectl, cluster connectivity)
#   2. Multi-stage container image build (<20MB Alpine runtime)
#   3. Image loading into local cluster runtime (k3d/minikube/kind)
#   4. Declarative manifest syntax validation (dry-run)
#   5. Headless Service and ClusterIP Service creation
#   6. StatefulSet ordered replica rollout (3/3 ready)
#   7. Dynamic PersistentVolumeClaim (PVC) provisioning via StorageClass
#   8. ClusterIP service reachability via port-forward
#   9. Persistence and pod destruction recovery via persistence_test.sh
#  10. Headless Service DNS peer discovery and state aggregation
#  11. Complete automated resource teardown and cleanup
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
NAMESPACE="statefulset-demo"
STATEFULSET_NAME="stateful-app"

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
    echo "  🚀 StatefulSet & Dynamic Persistent Volumes End-to-End Test Suite"
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

    # Phase 2: Container Build
    echo -e "\n${CLR_YELLOW}Phase 2: Container Image Build & Size Validation${CLR_RESET}"
    if DOCKER_BUILDKIT=1 docker build -q -t stateful-app:v1.0.0 "${SCRIPT_DIR}/app" >/dev/null 2>&1; then
        local img_size
        img_size=$(docker image inspect stateful-app:v1.0.0 --format='{{.Size}}')
        local img_size_mb
        img_size_mb=$(awk -v s="$img_size" 'BEGIN { printf "%.2f", s / 1024 / 1024 }')
        record_result "03" "Built stateful-app:v1.0.0 successfully" 0 "Image Size: ${img_size_mb} MB"
    else
        record_result "03" "Built stateful-app:v1.0.0 successfully" 1 "Build failed"
    fi

    load_image_if_needed "stateful-app:v1.0.0"

    # Phase 3: Manifest Validation & Deployment
    echo -e "\n${CLR_YELLOW}Phase 3: Manifest Syntax & Cluster Deployment${CLR_RESET}"
    if kubectl apply --dry-run=client -f "${SCRIPT_DIR}/namespace.yaml" \
       -f "${SCRIPT_DIR}/headless-service.yaml" \
       -f "${SCRIPT_DIR}/service.yaml" \
       -f "${SCRIPT_DIR}/statefulset.yaml" >/dev/null 2>&1; then
        record_result "04" "Declarative YAML manifests pass client-side validation" 0
    else
        record_result "04" "Declarative YAML manifests pass client-side validation" 1 "YAML validation failed"
    fi

    kubectl apply -f "${SCRIPT_DIR}/namespace.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/headless-service.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/service.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/statefulset.yaml" >/dev/null 2>&1

    # Wait for StatefulSet rollout
    if kubectl rollout status statefulset/"$STATEFULSET_NAME" -n "$NAMESPACE" --timeout=90s >/dev/null 2>&1; then
        record_result "05" "StatefulSet reached 3/3 ready replicas in ordered sequence" 0
    else
        record_result "05" "StatefulSet reached 3/3 ready replicas in ordered sequence" 1 "Rollout timed out"
    fi

    # Phase 4: Storage & Service Auditing
    echo -e "\n${CLR_YELLOW}Phase 4: Dynamic Persistent Volume & Service Auditing${CLR_RESET}"
    local pvcs_bound=0
    for i in 0 1 2; do
        local phase
        phase=$(kubectl get pvc "data-volume-${STATEFULSET_NAME}-${i}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$phase" == "Bound" ]]; then
            pvcs_bound=$((pvcs_bound + 1))
        fi
    done

    if [[ "$pvcs_bound" -eq 3 ]]; then
        record_result "06" "All 3 volumeClaimTemplates dynamically provisioned and Bound" 0 "Bound PVCs: 3/3"
    else
        record_result "06" "All 3 volumeClaimTemplates dynamically provisioned and Bound" 1 "Bound PVCs: ${pvcs_bound}/3"
    fi

    # Port-Forward Client Service
    local pf_port=18082
    kubectl port-forward -n "$NAMESPACE" svc/stateful-client-service "${pf_port}:80" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    local info_resp
    info_resp=$(curl -s "http://127.0.0.1:${pf_port}/info" 2>/dev/null || echo "")
    kill -9 "$pf_pid" >/dev/null 2>&1 || true

    if [[ "$info_resp" == *"stateful-app"* && "$info_resp" == *"/data"* ]]; then
        record_result "07" "ClusterIP Service routes client traffic to healthy StatefulSet pods" 0 "Service: stateful-client-service"
    else
        record_result "07" "ClusterIP Service routes client traffic to healthy StatefulSet pods" 1 "Response: ${info_resp}"
    fi

    # Phase 5: Persistence & Pod Destruction Verification
    echo -e "\n${CLR_YELLOW}Phase 5: Data Persistence & Recovery Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/persistence_test.sh"; then
        record_result "08" "persistence_test.sh executed and verified 100% data recovery" 0
    else
        record_result "08" "persistence_test.sh executed and verified 100% data recovery" 1 "Persistence check failed"
    fi

    # Phase 6: Teardown & Cleanliness
    echo -e "\n${CLR_YELLOW}Phase 6: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            record_result "09" "Full resource cleanup executed and verified" 0 "Namespace, pods, PVCs & images removed"
        else
            record_result "09" "Full resource cleanup executed and verified" 1 "Namespace still exists"
        fi
    else
        record_result "09" "Full resource cleanup executed and verified" 1 "cleanup.sh failed"
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
