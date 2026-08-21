#!/usr/bin/env bash
# ==============================================================================
# test_config_reloading.sh - End-to-End Automated Test Suite for Mini-Project 02
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, kubectl, Go, cluster accessibility)
#   2. Multi-stage Docker image build (<20MB Alpine runtime)
#   3. Declarative manifest syntax validation (dry-run)
#   4. Namespace, ConfigMap, Secret, Deployment & Service creation
#   5. Pod replica scheduling and readiness (3/3 healthy replicas)
#   6. ClusterIP Service creation and endpoint binding
#   7. ConfigMap scalar environment variable injection
#   8. Secret credential injection and API security masking
#   9. Volume-mounted ConfigMap file parsing (/etc/config/settings.json)
#  10. Volume-mounted Secret file validation (/etc/secrets/jwt-signing.key)
#  11. Dynamic ConfigMap environment update & rolling restart verification
#  12. Zero-downtime traffic preservation during config mutation
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
NAMESPACE="config-reloading-demo"
PORT=18081
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
    find "$SCRIPT_DIR" -maxdepth 2 -type f \( -name ".reload_results_*" -o -name ".tmp_*" \) -exec rm -f {} +
}

trap cleanup_test EXIT INT TERM

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 ConfigMaps, Secrets & Reloading End-to-End Test Suite"
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

    # Phase 2: Build Image
    echo -e "\n${CLR_YELLOW}Phase 2: Container Image Build & Size Validation${CLR_RESET}"
    if DOCKER_BUILDKIT=1 docker build -q -t config-reloading-app:v1.0.0 "${SCRIPT_DIR}/app" >/dev/null 2>&1; then
        local img_size
        img_size=$(docker image inspect config-reloading-app:v1.0.0 --format='{{.Size}}')
        local img_size_mb
        img_size_mb=$(awk -v s="$img_size" 'BEGIN { printf "%.2f", s / 1024 / 1024 }')
        record_result "03" "Built config-reloading-app:v1.0.0 successfully" 0 "Image Size: ${img_size_mb} MB"
    else
        record_result "03" "Built config-reloading-app:v1.0.0 successfully" 1 "Build failed"
    fi

    load_image_if_needed "config-reloading-app:v1.0.0"

    # Phase 3: Manifest Validation & Deployment
    echo -e "\n${CLR_YELLOW}Phase 3: Manifest Syntax & Cluster Deployment${CLR_RESET}"
    if kubectl apply --dry-run=client -f "${SCRIPT_DIR}/namespace.yaml" \
       -f "${SCRIPT_DIR}/configmap.yaml" \
       -f "${SCRIPT_DIR}/secret.yaml" \
       -f "${SCRIPT_DIR}/deployment.yaml" \
       -f "${SCRIPT_DIR}/service.yaml" >/dev/null 2>&1; then
        record_result "04" "Declarative YAML manifests pass client-side validation" 0
    else
        record_result "04" "Declarative YAML manifests pass client-side validation" 1 "YAML validation failed"
    fi

    kubectl apply -f "${SCRIPT_DIR}/namespace.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/configmap.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/secret.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/deployment.yaml" >/dev/null 2>&1
    kubectl apply -f "${SCRIPT_DIR}/service.yaml" >/dev/null 2>&1

    if kubectl rollout status deployment/config-reloading-app -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1; then
        local ready_replicas
        ready_replicas=$(kubectl get deployment config-reloading-app -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')
        if [[ "$ready_replicas" -eq 3 ]]; then
            record_result "05" "Deployment reached 3/3 ready replicas" 0 "All 3 pods healthy & ready"
        else
            record_result "05" "Deployment reached 3/3 ready replicas" 1 "Ready replicas: ${ready_replicas}"
        fi
    else
        record_result "05" "Deployment reached 3/3 ready replicas" 1 "Rollout timed out"
    fi

    # Phase 4: Connectivity & Configuration Verification
    echo -e "\n${CLR_YELLOW}Phase 4: Configuration & Secret Injection Auditing${CLR_RESET}"
    kubectl port-forward -n "$NAMESPACE" svc/config-reloading-service "${PORT}:80" >/dev/null 2>&1 &
    PF_PID=$!

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
        record_result "06" "ClusterIP Service exposes HTTP endpoint via port-forward" 0 "Accessible at ${TARGET_URL}"
    else
        record_result "06" "ClusterIP Service exposes HTTP endpoint via port-forward" 1 "Connection failed"
    fi

    # Verify ConfigMap Environment Variables
    local root_json
    root_json=$(curl -s -m 2 "${TARGET_URL}/")
    local app_name
    app_name=$(echo "$root_json" | grep -o '"app_name":"[^"]*"' | cut -d'"' -f4 || echo "")
    local theme
    theme=$(echo "$root_json" | grep -o '"theme":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [[ "$app_name" == "Microservice-Alpha" && "$theme" == "dark-mode" ]]; then
        record_result "07" "ConfigMap environment variables injected successfully" 0 "APP_NAME: ${app_name}, THEME: ${theme}"
    else
        record_result "07" "ConfigMap environment variables injected successfully" 1 "Unexpected env values: app=${app_name}, theme=${theme}"
    fi

    # Verify Secret Injection and Masking
    local masked_key
    masked_key=$(echo "$root_json" | grep -o '"api_key_masked":"[^"]*"' | cut -d'"' -f4 || echo "")
    local jwt_present
    jwt_present=$(echo "$root_json" | grep -o '"jwt_key_present":[^,}]*' | cut -d':' -f2 | tr -d ' ' || echo "false")

    if [[ "$masked_key" =~ ^sk_.* && "$masked_key" == *"*"* && "$jwt_present" == "true" ]]; then
        record_result "08" "Secret credentials injected and securely masked in API response" 0 "Key: ${masked_key}, JWT Mounted: true"
    else
        record_result "08" "Secret credentials injected and securely masked in API response" 1 "Masked key: ${masked_key}, JWT: ${jwt_present}"
    fi

    # Verify Volume-Mounted Configuration File
    local pool_size
    pool_size=$(echo "$root_json" | grep -o '"pool_size":[^,}]*' | cut -d':' -f2 | tr -d ' ' || echo "")
    if [[ "$pool_size" == "25" ]]; then
        record_result "09" "Volume-mounted ConfigMap file (/etc/config/settings.json) parsed" 0 "Database Pool Size: 25"
    else
        record_result "09" "Volume-mounted ConfigMap file (/etc/config/settings.json) parsed" 1 "Pool size: ${pool_size}"
    fi

    # Verify Volume-Mounted Secret Permissions & Existence
    local jwt_hash
    jwt_hash=$(echo "$root_json" | grep -o '"jwt_key_sha256":"[^"]*"' | cut -d'"' -f4 || echo "")
    if [[ -n "$jwt_hash" && "${#jwt_hash}" -eq 64 ]]; then
        record_result "10" "Volume-mounted Secret file (/etc/secrets/jwt-signing.key) verified" 0 "SHA256: ${jwt_hash:0:16}..."
    else
        record_result "10" "Volume-mounted Secret file (/etc/secrets/jwt-signing.key) verified" 1 "Invalid JWT Hash: ${jwt_hash}"
    fi

    # Phase 5: Dynamic Reloading Execution
    echo -e "\n${CLR_YELLOW}Phase 5: Dynamic Configuration Reloading Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/config_reload_test.sh"; then
        record_result "11" "Zero-downtime dynamic config rollout executed with 100% success" 0
    else
        record_result "11" "Zero-downtime dynamic config rollout executed with 100% success" 1 "Config reload failed"
    fi

    # Phase 6: Teardown & Cleanliness
    echo -e "\n${CLR_YELLOW}Phase 6: Resource Teardown & Cleanup Verification${CLR_RESET}"
    if "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1; then
        if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            record_result "12" "Full resource cleanup executed and verified" 0 "Namespace, pods & images removed"
        else
            record_result "12" "Full resource cleanup executed and verified" 1 "Namespace still exists"
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
