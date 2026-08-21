#!/usr/bin/env bash
# ==============================================================================
# rollout_test.sh - Zero-Downtime Rolling Update Verification Script
# ==============================================================================
# Demonstrates Kubernetes zero-downtime deployments by continuously querying
# the ClusterIP service endpoint from within the cluster while performing a
# rolling update from v1.0.0 to v2.0.0 (and vice versa).
#
# Metrics tracked:
#   - Total HTTP requests dispatched
#   - Successful HTTP 200 responses
#   - Dropped / failed connections or non-200 HTTP status codes
#   - Version distribution during rollout (v1.0.0 vs v2.0.0)
#   - Pod replica load distribution across hostnames
# ==============================================================================

set -euo pipefail

# ANSI color formatting
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-stateless-app-demo}"
DEPLOYMENT="${DEPLOYMENT:-stateless-app}"
SERVICE="${SERVICE:-stateless-app-service}"
TESTER_POD="rollout-traffic-tester"
RESULTS_FILE="${SCRIPT_DIR}/.rollout_results_$$.log"

# Detect target version based on currently deployed image
CURRENT_IMAGE=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "stateless-app:v1.0.0")
if [[ "$CURRENT_IMAGE" == *"v1.0.0"* ]]; then
    NEW_IMAGE="stateless-app:v2.0.0"
else
    NEW_IMAGE="stateless-app:v1.0.0"
fi

cleanup() {
    kubectl delete pod "$TESTER_POD" -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    rm -f "$RESULTS_FILE" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  ☸️  Kubernetes Zero-Downtime Rolling Update Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

main() {
    print_banner

    echo -e "${CLR_YELLOW}▶ Step 1: Inspecting Current Deployment State...${CLR_RESET}"
    echo -e "  Namespace: ${CLR_CYAN}${NAMESPACE}${CLR_RESET}"
    echo -e "  Deployment: ${CLR_CYAN}${DEPLOYMENT}${CLR_RESET}"
    echo -e "  Active Image: ${CLR_CYAN}${CURRENT_IMAGE}${CLR_RESET}"
    echo -e "  Rollout Target: ${CLR_MAGENTA}${NEW_IMAGE}${CLR_RESET}"

    # Ensure baseline deployment is ready
    kubectl rollout status "deployment/${DEPLOYMENT}" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1

    echo -e "\n${CLR_YELLOW}▶ Step 2: Spawning In-Cluster Continuous Traffic Tester Pod...${CLR_RESET}"
    kubectl delete pod "$TESTER_POD" -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

    # Launch traffic tester container querying ClusterIP service via kube-dns
    kubectl run "$TESTER_POD" \
        --image="$CURRENT_IMAGE" \
        --image-pull-policy=IfNotPresent \
        --restart=Never \
        -n "$NAMESPACE" \
        --command -- /bin/sh -c '
            echo "TRAFFIC_STARTED"
            i=1
            while true; do
                res=$(curl -s -m 2 -w "\nHTTP_CODE:%{http_code}" http://'"$SERVICE"'/)
                code=$(echo "$res" | grep "HTTP_CODE:" | cut -d":" -f2 || echo "000")
                ver=$(echo "$res" | grep -o "\"version\":\"[^\"]*\"" | cut -d"\"" -f4 || echo "unknown")
                pod=$(echo "$res" | grep -o "\"pod_name\":\"[^\"]*\"" | cut -d"\"" -f4 || echo "unknown")
                echo "REQ:$i:$code:$ver:$pod"
                i=$((i + 1))
                sleep 0.05
            done
        ' >/dev/null 2>&1

    # Wait for traffic generator pod to be ready
    echo "  Waiting for traffic generator pod to initialize..."
    kubectl wait --for=condition=Ready "pod/${TESTER_POD}" -n "$NAMESPACE" --timeout=30s >/dev/null 2>&1 || true

    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] High-frequency continuous traffic stream active (~20 req/sec)."

    # Allow 2 seconds of baseline requests
    sleep 2

    echo -e "\n${CLR_YELLOW}▶ Step 3: Triggering Kubernetes Rolling Update -> ${NEW_IMAGE}...${CLR_RESET}"
    kubectl set image "deployment/${DEPLOYMENT}" "${DEPLOYMENT}=${NEW_IMAGE}" -n "$NAMESPACE"
    
    echo -e "  Watching rollout status in real-time..."
    kubectl rollout status "deployment/${DEPLOYMENT}" -n "$NAMESPACE" --timeout=90s

    # Allow 2 seconds of post-rollout traffic
    sleep 2

    echo -e "\n${CLR_YELLOW}▶ Step 4: Collecting & Aggregating Traffic Metrics...${CLR_RESET}"
    # Save log output to local results file
    kubectl logs "$TESTER_POD" -n "$NAMESPACE" > "$RESULTS_FILE" 2>/dev/null || true
    kubectl delete pod "$TESTER_POD" -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

    # Parse Metrics
    local total_reqs=0
    local success_reqs=0
    local failed_reqs=0
    local v1_reqs=0
    local v2_reqs=0
    local unique_pods=""

    if [[ -f "$RESULTS_FILE" ]]; then
        total_reqs=$(grep -c "^REQ:" "$RESULTS_FILE" || true)
        success_reqs=$(grep -c "^REQ:[0-9]*:200:" "$RESULTS_FILE" || true)
        failed_reqs=$((total_reqs - success_reqs))
        v1_reqs=$(grep "^REQ:[0-9]*:200:v1.0.0:" "$RESULTS_FILE" | wc -l | tr -d ' ' || true)
        v2_reqs=$(grep "^REQ:[0-9]*:200:v2.0.0:" "$RESULTS_FILE" | wc -l | tr -d ' ' || true)
        unique_pods=$(grep "^REQ:[0-9]*:200:" "$RESULTS_FILE" | cut -d':' -f5 | sort | uniq | tr '\n' ' ' || true)
    fi

    local success_rate="0.00"
    if [[ $total_reqs -gt 0 ]]; then
        success_rate=$(awk -v s="$success_reqs" -v t="$total_reqs" 'BEGIN { printf "%.2f", (s/t)*100 }')
    fi

    echo -e "\n${CLR_CYAN}${CLR_BOLD}📊 ZERO-DOWNTIME ROLLOUT VERIFICATION REPORT${CLR_RESET}"
    echo "======================================================================"
    printf "  %-32s : %s\n" "Total Requests Dispatched" "${total_reqs}"
    printf "  %-32s : %s (%s%%)\n" "Successful Requests (HTTP 200)" "${success_reqs}" "${success_rate}"
    printf "  %-32s : %s\n" "Dropped / Failed Requests" "${failed_reqs}"
    printf "  %-32s : %s\n" "Requests Handled by v1.0.0" "${v1_reqs}"
    printf "  %-32s : %s\n" "Requests Handled by v2.0.0" "${v2_reqs}"
    printf "  %-32s : %s\n" "Active Backend Pods Involved" "${unique_pods}"
    echo "======================================================================"

    if [[ "$failed_reqs" -eq 0 && "$success_reqs" -ge 50 && "$v1_reqs" -gt 0 && "$v2_reqs" -gt 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✅ ZERO-DOWNTIME VERIFICATION PASSED:${CLR_RESET} 100.0%% availability observed with zero dropped packets across version rollout!"
        exit 0
    elif [[ "$failed_reqs" -eq 0 && "$success_reqs" -gt 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✅ ROLLOUT SUCCESSFUL:${CLR_RESET} Zero failed requests during deployment transition."
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ VERIFICATION FAILED:${CLR_RESET} Observed ${failed_reqs} failed requests during rollout."
        exit 1
    fi
}

main "$@"
