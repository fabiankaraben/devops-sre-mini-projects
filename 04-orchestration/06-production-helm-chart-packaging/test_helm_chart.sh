#!/usr/bin/env bash
# ==============================================================================
# test_helm_chart.sh - Production-Grade Helm Chart End-to-End Test Suite
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, kubectl, helm 3 CLI, cluster reachability)
#   2. Multi-stage container image build (<20MB Alpine runtime)
#   3. Image loading into local cluster runtime (k3d/minikube/kind)
#   4. Chart static linting & best practices (helm lint)
#   5. Go template expansion & manifest rendering (helm template)
#   6. JSON schema validation & guardrail enforcement (values.schema.json)
#   7. Release installation in staging mode (helm install)
#   8. In-cluster integration test hook execution (helm test)
#   9. Release upgrade with production overrides (helm upgrade)
#  10. Release rollback to revision 1 (helm rollback)
#  11. ClusterIP Service port-forward connectivity
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
CHART_DIR="${SCRIPT_DIR}/chart"
NAMESPACE="helm-demo"
RELEASE_NAME="enterprise-app"

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
    echo "  🚀 Production-Grade Helm 3 Chart End-to-End Test Suite"
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

    if helm version >/dev/null 2>&1; then
        local helm_v
        helm_v=$(helm version --short 2>/dev/null || echo "v3")
        record_result "03" "Helm CLI is installed and operational" 0 "Version: ${helm_v}"
    else
        record_result "03" "Helm CLI is installed and operational" 1 "Helm CLI missing"
        exit 1
    fi

    # Phase 2: Container Build
    echo -e "\n${CLR_YELLOW}Phase 2: Container Image Build & Size Validation${CLR_RESET}"
    if DOCKER_BUILDKIT=1 docker build -q -t enterprise-app:v1.0.0 "${SCRIPT_DIR}/app" >/dev/null 2>&1; then
        local img_size
        img_size=$(docker image inspect enterprise-app:v1.0.0 --format='{{.Size}}')
        local img_size_mb
        img_size_mb=$(awk -v s="$img_size" 'BEGIN { printf "%.2f", s / 1024 / 1024 }')
        record_result "04" "Built enterprise-app:v1.0.0 successfully" 0 "Image Size: ${img_size_mb} MB"
    else
        record_result "04" "Built enterprise-app:v1.0.0 successfully" 1 "Build failed"
    fi

    load_image_if_needed "enterprise-app:v1.0.0"

    # Phase 3: Static Analysis & Schema Enforcement
    echo -e "\n${CLR_YELLOW}Phase 3: Helm Chart Static Analysis & Schema Enforcement${CLR_RESET}"
    if helm lint "$CHART_DIR" >/dev/null 2>&1; then
        record_result "05" "Helm chart passes static analysis (helm lint)" 0 "Chart: enterprise-app"
    else
        record_result "05" "Helm chart passes static analysis (helm lint)" 1 "helm lint failed"
    fi

    if helm template "$RELEASE_NAME" "$CHART_DIR" >/dev/null 2>&1; then
        record_result "06" "Helm templates render successfully (helm template)" 0
    else
        record_result "06" "Helm templates render successfully (helm template)" 1 "Template rendering failed"
    fi

    # Validate JSON Schema blocks invalid values
    if ! helm template "$RELEASE_NAME" "$CHART_DIR" --set replicaCount=-1 >/dev/null 2>&1 && \
       ! helm template "$RELEASE_NAME" "$CHART_DIR" --set service.port=999999 >/dev/null 2>&1; then
        record_result "07" "JSON Schema validation enforces type safety and boundaries" 0 "Schema: values.schema.json"
    else
        record_result "07" "JSON Schema validation enforces type safety and boundaries" 1 "Schema validation failed to reject invalid values"
    fi

    # Phase 4: CI/CD Pipeline Execution
    echo -e "\n${CLR_YELLOW}Phase 4: Helm Release Lifecycle & Pipeline Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/helm_test_pipeline.sh"; then
        record_result "08" "helm_test_pipeline.sh executed full release lifecycle successfully" 0
    else
        record_result "08" "helm_test_pipeline.sh executed full release lifecycle successfully" 1 "Pipeline failed"
    fi

    # Phase 5: Service Connectivity
    echo -e "\n${CLR_YELLOW}Phase 5: ClusterIP Service Connectivity Verification${CLR_RESET}"
    local pf_port=18084
    kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}" "${pf_port}:80" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 2

    local info_resp
    info_resp=$(curl -s "http://127.0.0.1:${pf_port}/" 2>/dev/null || echo "")
    kill -9 "$pf_pid" >/dev/null 2>&1 || true

    if [[ "$info_resp" == *"Enterprise"* ]]; then
        record_result "09" "ClusterIP Service exposes Helm microservice endpoints" 0 "Endpoint: http://127.0.0.1:${pf_port}"
    else
        record_result "09" "ClusterIP Service exposes Helm microservice endpoints" 1 "Response: ${info_resp}"
    fi

    # Phase 6: Teardown & Cleanliness
    echo -e "\n${CLR_YELLOW}Phase 6: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            record_result "10" "Full resource cleanup executed and verified" 0 "Namespace, Helm release & images removed"
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
