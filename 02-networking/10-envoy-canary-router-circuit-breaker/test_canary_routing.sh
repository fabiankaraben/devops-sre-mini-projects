#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for Envoy L7 Canary Router and Circuit Breaker
# ==============================================================================
# Verifies:
#   1. Service health checks (Envoy Ingress :10000, Admin :9901, V1 :8001, V2 :8002)
#   2. Header-based canary override (x-canary: true -> 100% V2)
#   3. Statistical 90/10 weighted canary traffic distribution (1000 requests)
#   4. Outlier detection circuit breaking on consecutive 500 errors
#   5. Envoy Prometheus metrics validation (outlier detection ejections counter)
#   6. Full cluster state and active observability inspection
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"

ENVOY_URL="http://localhost:10000"
ENVOY_ADMIN_URL="http://localhost:9901"
V1_URL="http://localhost:8001"
V2_URL="http://localhost:8002"
VERBOSE=false

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🔀 Envoy L7 Canary Router & Circuit Breaker Automated Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
    echo -e "${CLR_GRAY}Envoy Ingress    : ${CLR_BOLD}${ENVOY_URL}${CLR_RESET}"
    echo -e "${CLR_GRAY}Envoy Admin      : ${CLR_BOLD}${ENVOY_ADMIN_URL}${CLR_RESET}"
    echo -e "${CLR_GRAY}Stable Service V1: ${CLR_BOLD}${V1_URL}${CLR_RESET}"
    echo -e "${CLR_GRAY}Canary Service V2: ${CLR_BOLD}${V2_URL}${CLR_RESET}\n"
}

show_help() {
    echo "Usage: ./test_canary_routing.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose       Display detailed JSON outputs and diagnostics"
    echo "  -h, --help          Display this help menu"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}"
            show_help
            exit 1
            ;;
    esac
done

record_result() {
    local test_name="$1"
    local status="$2"
    local details="${3:-}"

    ((TOTAL_TESTS++))
    if [ "$status" -eq 0 ]; then
        ((PASSED_TESTS++))
        echo -e "  [ ${CLR_GREEN}PASS${CLR_RESET} ] ${test_name}"
        if [ "$VERBOSE" = true ] && [ -n "$details" ]; then
            echo -e "         ${CLR_GRAY}${details}${CLR_RESET}"
        fi
    else
        ((FAILED_TESTS++))
        echo -e "  [ ${CLR_RED}FAIL${CLR_RESET} ] ${test_name}"
        if [ -n "$details" ]; then
            echo -e "         ${CLR_YELLOW}Reason: ${details}${CLR_RESET}"
        fi
    fi
}

section_header() {
    echo -e "\n${CLR_BLUE}${CLR_BOLD}▶ $1${CLR_RESET}"
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"
}

# ------------------------------------------------------------------------------
# Test 1: Service Health Checks
# ------------------------------------------------------------------------------
test_service_health() {
    section_header "1. Service Readiness & Health Checks"

    # Reset any active faults on Canary V2 and allow cooldown to clear
    curl -s -X POST "${V2_URL}/api/canary/simulate-fault" \
        -H "Content-Type: application/json" \
        -d '{"enabled": false}' >/dev/null 2>&1 || true
    sleep 4.2

    # Envoy Ingress
    local envoy_res
    if envoy_res=$(curl -s -m 3 "${ENVOY_URL}/health" 2>&1); then
        if echo "$envoy_res" | grep -q "envoy"; then
            record_result "Envoy L7 Router (:10000/health) healthy" 0 "$envoy_res"
        else
            record_result "Envoy L7 Router (:10000/health)" 1 "Unexpected response: $envoy_res"
        fi
    else
        record_result "Envoy L7 Router (:10000/health)" 1 "$envoy_res"
    fi

    # Envoy Admin
    local admin_res
    if admin_res=$(curl -s -m 3 "${ENVOY_ADMIN_URL}/ready" 2>&1); then
        if echo "$admin_res" | grep -q "LIVE"; then
            record_result "Envoy Admin API (:9901/ready) LIVE" 0 "$admin_res"
        else
            record_result "Envoy Admin API (:9901/ready)" 1 "Unexpected response: $admin_res"
        fi
    else
        record_result "Envoy Admin API (:9901/ready)" 1 "$admin_res"
    fi

    # Service V1
    local v1_res
    if v1_res=$(curl -s -m 3 "${V1_URL}/health" 2>&1); then
        if echo "$v1_res" | grep -q "service_v1"; then
            record_result "Stable Service V1 (:8001/health) healthy" 0 "$v1_res"
        else
            record_result "Stable Service V1 (:8001/health)" 1 "Unexpected response: $v1_res"
        fi
    else
        record_result "Stable Service V1 (:8001/health)" 1 "$v1_res"
    fi

    # Service V2
    local v2_res
    if v2_res=$(curl -s -m 3 "${V2_URL}/health" 2>&1); then
        if echo "$v2_res" | grep -q "service_v2"; then
            record_result "Canary Service V2 (:8002/health) healthy" 0 "$v2_res"
        else
            record_result "Canary Service V2 (:8002/health)" 1 "Unexpected response: $v2_res"
        fi
    else
        record_result "Canary Service V2 (:8002/health)" 1 "$v2_res"
    fi
}

# ------------------------------------------------------------------------------
# Test 2: Header-Based Canary Override Test (x-canary: true)
# ------------------------------------------------------------------------------
test_header_override() {
    section_header "2. Header-Based Canary Override Routing (x-canary: true -> 100% V2)"

    local override_count=0
    for _ in {1..20}; do
        local body
        body=$(curl -s -H "x-canary: true" "${ENVOY_URL}/api/v1/data" || echo "")
        if echo "$body" | grep -q "v2.0.0"; then
            ((override_count++))
        fi
    done

    if [ "$override_count" -eq 20 ]; then
        record_result "Header Override: 20/20 requests with 'x-canary: true' routed to V2 Canary" 0
    else
        record_result "Header Override Check" 1 "Only ${override_count}/20 routed to V2"
    fi
}

# ------------------------------------------------------------------------------
# Test 3: Statistical 90/10 Weighted Canary Traffic Shifting
# ------------------------------------------------------------------------------
test_weighted_traffic_split() {
    section_header "3. Statistical 90/10 Weighted Canary Traffic Shifting (1000 requests)"

    echo -e "${CLR_GRAY}Executing statistical load generator canary_verification.py...${CLR_RESET}"
    if python3 canary_verification.py --target "$ENVOY_URL" --canary-backend "$V2_URL" --envoy-admin "$ENVOY_ADMIN_URL" --requests 1000 --concurrency 10; then
        record_result "Statistical 90/10 Canary Split Verified (1000 requests within tolerance)" 0
    else
        record_result "Statistical 90/10 Canary Split Check" 1 "Distribution was out of tolerance"
    fi
}

# ------------------------------------------------------------------------------
# Test 4: Outlier Detection Circuit Breaking on Consecutive 500s
# ------------------------------------------------------------------------------
test_outlier_detection_ejection() {
    section_header "4. Outlier Detection Circuit Breaking on Consecutive 500 Errors"

    # Inject 500 error into Canary Service V2
    echo -e "${CLR_GRAY}Injecting 500 errors into Service V2 to trigger outlier detection...${CLR_RESET}"
    curl -s -X POST "${V2_URL}/api/canary/simulate-fault" \
        -H "Content-Type: application/json" \
        -d '{"enabled": true, "status_code": 500, "count": 20}' >/dev/null

    # Send requests to trigger 3 consecutive 5xx errors
    for _ in {1..8}; do
        curl -s -H "x-canary: true" "${ENVOY_URL}/api/v1/data" >/dev/null 2>&1 || true
    done
    sleep 1.2

    # Query Envoy Admin for outlier detection ejections on service_v2
    local ejections_enforced
    ejections_enforced=$(curl -s "${ENVOY_ADMIN_URL}/stats?filter=cluster.service_v2.outlier_detection.ejections_enforced_total" | grep "ejections_enforced_total:" | awk '{print $2}' || echo "0")

    if [ "$ejections_enforced" -ge 1 ]; then
        record_result "Outlier Detection: Service V2 host ejected after consecutive 500 errors (enforced=${ejections_enforced})" 0
    else
        record_result "Outlier Detection Check" 1 "Ejections counter remained 0"
    fi

    # Reset fault simulation
    curl -s -X POST "${V2_URL}/api/canary/simulate-fault" \
        -H "Content-Type: application/json" \
        -d '{"enabled": false}' >/dev/null
}

# ------------------------------------------------------------------------------
# Test 5: Envoy Prometheus Metrics Export Verification
# ------------------------------------------------------------------------------
test_prometheus_metrics() {
    section_header "5. Envoy Prometheus Metrics Export Verification"

    local prom_count
    prom_count=$(curl -s "${ENVOY_ADMIN_URL}/stats/prometheus" | grep -c "outlier_detection" || echo "0")

    if [ "$prom_count" -gt 0 ]; then
        record_result "Envoy Prometheus Metrics (:9901/stats/prometheus) active (${prom_count} outlier metrics exported)" 0
    else
        record_result "Envoy Prometheus Metrics check" 1 "Outlier detection metrics not found in Prometheus output"
    fi
}

# ------------------------------------------------------------------------------
# Test 6: Envoy Cluster State & Endpoint Inspection
# ------------------------------------------------------------------------------
test_cluster_endpoints() {
    section_header "6. Envoy Cluster State & Endpoint Inspection"

    local clusters_out
    clusters_out=$(curl -s "${ENVOY_ADMIN_URL}/clusters")

    if echo "$clusters_out" | grep -q "service_v1" && echo "$clusters_out" | grep -q "service_v2"; then
        record_result "Envoy Cluster Configuration: service_v1 and service_v2 registered in load balancer" 0
    else
        record_result "Envoy Cluster Configuration check" 1 "Clusters missing in admin output"
    fi
}

# ------------------------------------------------------------------------------
# Main Execution Flow & Summary
# ------------------------------------------------------------------------------
main() {
    local start_time
    start_time=$(date +%s)

    print_banner
    test_service_health
    test_header_override
    test_weighted_traffic_split
    test_outlier_detection_ejection
    test_prometheus_metrics
    test_cluster_endpoints

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}                         TEST SUMMARY REPORT                          ${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "  Total Tests Executed : ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
    echo -e "  Passed Tests         : ${CLR_GREEN}${CLR_BOLD}${PASSED_TESTS}${CLR_RESET}"
    echo -e "  Failed Tests         : ${CLR_RED}${CLR_BOLD}${FAILED_TESTS}${CLR_RESET}"
    echo -e "  Total Duration       : ${CLR_BOLD}${duration}s${CLR_RESET}"

    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "\n  ${CLR_GREEN}${CLR_BOLD}🎉 ALL ENVOY L7 CANARY & CIRCUIT BREAKER TESTS PASSED!${CLR_RESET}\n"
        exit 0
    else
        echo -e "\n  ${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. Check output above.${CLR_RESET}\n"
        exit 1
    fi
}

main
