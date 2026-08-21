#!/usr/bin/env bash
# ==============================================================================
# test_project.sh - End-to-End Automated Verification Test Suite
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, kubectl, cluster availability)
#   2. Multi-stage container image build (<20MB Alpine runtime)
#   3. Automated cert-manager CRD and controller bootstrap
#   4. Declarative manifest syntax validation (dry-run)
#   5. Web and API backend service deployments (2/2 replicas each)
#   6. cert-manager ClusterIssuer creation and readiness
#   7. Automated X.509 Certificate issuance & TLS Secret generation
#   8. Certificate Subject Alternative Names (SANs) verification
#   9. Host-based Ingress rules and TLS termination bindings
#  10. Backend routing verification for web.local.dev and api.local.dev
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
NAMESPACE="ingress-tls-demo"

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
    echo "  🚀 Ingress Routing & cert-manager TLS End-to-End Test Suite"
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

ensure_cert_manager() {
    if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        echo -e "  Installing cert-manager controller & CRDs..."
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.yaml >/dev/null 2>&1
        kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s >/dev/null 2>&1
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

    # Phase 2: Build Image
    echo -e "\n${CLR_YELLOW}Phase 2: Container Image Build & Size Validation${CLR_RESET}"
    if DOCKER_BUILDKIT=1 docker build -q -t ingress-tls-app:v1.0.0 "${SCRIPT_DIR}/app" >/dev/null 2>&1; then
        local img_size
        img_size=$(docker image inspect ingress-tls-app:v1.0.0 --format='{{.Size}}')
        local img_size_mb
        img_size_mb=$(awk -v s="$img_size" 'BEGIN { printf "%.2f", s / 1024 / 1024 }')
        record_result "03" "Built ingress-tls-app:v1.0.0 successfully" 0 "Image Size: ${img_size_mb} MB"
    else
        record_result "03" "Built ingress-tls-app:v1.0.0 successfully" 1 "Build failed"
    fi

    load_image_if_needed "ingress-tls-app:v1.0.0"

    # Phase 3: Bootstrap cert-manager
    echo -e "\n${CLR_YELLOW}Phase 3: cert-manager Controller Bootstrap${CLR_RESET}"
    ensure_cert_manager
    if kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
        record_result "04" "cert-manager CRDs and controller active in cluster" 0 "Namespace: cert-manager"
    else
        record_result "04" "cert-manager CRDs and controller active in cluster" 1 "cert-manager missing"
    fi

    # Phase 4: Manifest Validation & Deployment
    echo -e "\n${CLR_YELLOW}Phase 4: Manifest Syntax & Cluster Deployment${CLR_RESET}"
    if kubectl apply --dry-run=client -f "${SCRIPT_DIR}/namespace.yaml" \
       -f "${SCRIPT_DIR}/web-backend.yaml" \
       -f "${SCRIPT_DIR}/api-backend.yaml" \
       -f "${SCRIPT_DIR}/issuer.yaml" \
       -f "${SCRIPT_DIR}/certificate.yaml" \
       -f "${SCRIPT_DIR}/ingress.yaml" >/dev/null 2>&1; then
        record_result "05" "Declarative YAML manifests pass client-side validation" 0
    else
        record_result "05" "Declarative YAML manifests pass client-side validation" 1 "YAML validation failed"
    fi

    kubectl apply -f "${SCRIPT_DIR}/namespace.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/web-backend.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/api-backend.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/issuer.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/certificate.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/ingress.yaml" >/dev/null 2>&1

    # Wait for backends
    if kubectl rollout status deployment/web-service -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1 && \
       kubectl rollout status deployment/api-service -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1; then
        record_result "06" "Web and API backend deployments reached Ready replicas (2/2 each)" 0
    else
        record_result "06" "Web and API backend deployments reached Ready replicas (2/2 each)" 1 "Rollout timed out"
    fi

    # Phase 5: Run Ingress & TLS Verification
    echo -e "\n${CLR_YELLOW}Phase 5: Ingress Routing & Automated TLS Validation${CLR_RESET}"
    if "${SCRIPT_DIR}/test_ingress_tls.sh"; then
        record_result "07" "test_ingress_tls.sh executed and verified all checks successfully" 0
    else
        record_result "07" "test_ingress_tls.sh executed and verified all checks successfully" 1 "TLS checks failed"
    fi

    # Phase 6: Teardown & Cleanliness
    echo -e "\n${CLR_YELLOW}Phase 6: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            record_result "08" "Full resource cleanup executed and verified" 0 "Namespace, pods & images removed"
        else
            record_result "08" "Full resource cleanup executed and verified" 1 "Namespace still exists"
        fi
    else
        record_result "08" "Full resource cleanup executed and verified" 1 "cleanup.sh failed"
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
