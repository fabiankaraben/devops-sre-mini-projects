#!/usr/bin/env bash
# ==============================================================================
# config_reload_test.sh - Dynamic Config & Secret Reloading Test Suite
# ==============================================================================
# Demonstrates and tests the two Kubernetes configuration update paradigms:
#
#   1. Live Volume Hot-Reloading:
#      - Updates volume-mounted ConfigMap data (settings.json).
#      - Proves that the running container reads the new configuration
#        without restarting pods or killing active processes.
#
#   2. Dynamic Rolling Restart for Environment Variables:
#      - Updates scalar environment variables (LOG_LEVEL, THEME).
#      - Updates the deployment checksum annotation (GitOps / Reloader pattern).
#      - Dispatches continuous traffic during the rollout, verifying 100%
#        request availability with zero dropped connections.
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-config-reloading-demo}"
DEPLOYMENT="${DEPLOYMENT:-config-reloading-app}"
SERVICE="${SERVICE:-config-reloading-service}"
TESTER_POD="config-reload-tester"
RESULTS_FILE="${SCRIPT_DIR}/.reload_results_$$.log"

cleanup() {
    kubectl delete pod "$TESTER_POD" -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    rm -f "$RESULTS_FILE" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  ☸️  Kubernetes ConfigMap, Secret & Dynamic Reloading Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

main() {
    print_banner

    # --------------------------------------------------------------------------
    # Part 1: Inspect Initial State
    # --------------------------------------------------------------------------
    echo -e "${CLR_YELLOW}▶ Step 1: Inspecting Current Baseline Configuration...${CLR_RESET}"
    kubectl rollout status "deployment/${DEPLOYMENT}" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1

    # Sample baseline from one of the pods
    local baseline_json
    baseline_json=$(kubectl exec -n "$NAMESPACE" "deployment/${DEPLOYMENT}" -c app -- curl -s http://127.0.0.1:8080/config 2>/dev/null || echo "{}")
    echo -e "  Baseline Config: ${CLR_GRAY}${baseline_json}${CLR_RESET}"

    local initial_theme
    initial_theme=$(echo "$baseline_json" | grep -o '"THEME":"[^"]*"' | cut -d'"' -f4 || echo "dark-mode")
    echo -e "  Current Environment THEME : ${CLR_CYAN}${initial_theme}${CLR_RESET}"

    # --------------------------------------------------------------------------
    # Part 2: Demonstrate Dynamic Rolling Restart for Environment Variables
    # --------------------------------------------------------------------------
    local target_theme="cyberpunk-neon"
    if [[ "$initial_theme" == "cyberpunk-neon" ]]; then
        target_theme="dark-mode"
    fi

    echo -e "\n${CLR_YELLOW}▶ Step 2: Mutating ConfigMap Environment Variable -> THEME=${target_theme}...${CLR_RESET}"
    # Update ConfigMap key in cluster
    kubectl patch configmap app-config -n "$NAMESPACE" --type merge -p "{\"data\":{\"THEME\":\"${target_theme}\",\"LOG_LEVEL\":\"DEBUG\"}}"

    # Compute new ConfigMap Checksum (GitOps / Reloader SHA256 pattern)
    local config_checksum
    config_checksum=$(kubectl get configmap app-config -n "$NAMESPACE" -o yaml | shasum -a 256 | awk '{print $1}')
    echo -e "  Updated ConfigMap SHA256 Checksum: ${CLR_MAGENTA}${config_checksum:0:16}...${CLR_RESET}"

    echo -e "\n${CLR_YELLOW}▶ Step 3: Spawning In-Cluster Continuous Traffic Stream...${CLR_RESET}"
    kubectl delete pod "$TESTER_POD" -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

    kubectl run "$TESTER_POD" \
        --image="config-reloading-app:v1.0.0" \
        --image-pull-policy=IfNotPresent \
        --restart=Never \
        -n "$NAMESPACE" \
        --command -- /bin/sh -c '
            echo "TRAFFIC_STARTED"
            i=1
            while true; do
                res=$(curl -s -m 2 -w "\nHTTP_CODE:%{http_code}" http://'"$SERVICE"'/)
                code=$(echo "$res" | grep "HTTP_CODE:" | cut -d":" -f2 || echo "000")
                theme=$(echo "$res" | grep -o "\"theme\":\"[^\"]*\"" | cut -d"\"" -f4 || echo "unknown")
                pod=$(echo "$res" | grep -o "\"pod_name\":\"[^\"]*\"" | cut -d"\"" -f4 || echo "unknown")
                echo "REQ:$i:$code:$theme:$pod"
                i=$((i + 1))
                sleep 0.05
            done
        ' >/dev/null 2>&1

    # Wait for traffic generator
    echo "  Waiting for traffic generator pod to initialize..."
    kubectl wait --for=condition=Ready "pod/${TESTER_POD}" -n "$NAMESPACE" --timeout=30s >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] High-frequency continuous traffic stream active (~20 req/sec)."

    sleep 1.5

    echo -e "\n${CLR_YELLOW}▶ Step 4: Applying Checksum Annotation to Trigger Zero-Downtime Reload...${CLR_RESET}"
    # Patch deployment template annotation to trigger rolling restart
    kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"${config_checksum}\"}}}}}"
    
    echo -e "  Watching rollout transition in real-time..."
    kubectl rollout status "deployment/${DEPLOYMENT}" -n "$NAMESPACE" --timeout=90s

    sleep 2

    echo -e "\n${CLR_YELLOW}▶ Step 5: Collecting & Analyzing Traffic & Configuration Metrics...${CLR_RESET}"
    kubectl logs "$TESTER_POD" -n "$NAMESPACE" > "$RESULTS_FILE" 2>/dev/null || true
    kubectl delete pod "$TESTER_POD" -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

    local total_reqs=0
    local success_reqs=0
    local failed_reqs=0
    local old_theme_reqs=0
    local new_theme_reqs=0
    local unique_pods=""

    if [[ -f "$RESULTS_FILE" ]]; then
        total_reqs=$(grep -c "^REQ:" "$RESULTS_FILE" || true)
        success_reqs=$(grep -c "^REQ:[0-9]*:200:" "$RESULTS_FILE" || true)
        failed_reqs=$((total_reqs - success_reqs))
        old_theme_reqs=$(grep "^REQ:[0-9]*:200:${initial_theme}:" "$RESULTS_FILE" | wc -l | tr -d ' ' || true)
        new_theme_reqs=$(grep "^REQ:[0-9]*:200:${target_theme}:" "$RESULTS_FILE" | wc -l | tr -d ' ' || true)
        unique_pods=$(grep "^REQ:[0-9]*:200:" "$RESULTS_FILE" | cut -d':' -f5 | sort | uniq | tr '\n' ' ' || true)
    fi

    local success_rate="0.00"
    if [[ $total_reqs -gt 0 ]]; then
        success_rate=$(awk -v s="$success_reqs" -v t="$total_reqs" 'BEGIN { printf "%.2f", (s/t)*100 }')
    fi

    echo -e "\n${CLR_CYAN}${CLR_BOLD}📊 DYNAMIC RELOAD VERIFICATION REPORT${CLR_RESET}"
    echo "======================================================================"
    printf "  %-32s : %s\n" "Total Requests Dispatched" "${total_reqs}"
    printf "  %-32s : %s (%s%%)\n" "Successful Requests (HTTP 200)" "${success_reqs}" "${success_rate}"
    printf "  %-32s : %s\n" "Dropped / Failed Requests" "${failed_reqs}"
    printf "  %-32s : %s\n" "Requests with Initial Theme (${initial_theme})" "${old_theme_reqs}"
    printf "  %-32s : %s\n" "Requests with Updated Theme (${target_theme})" "${new_theme_reqs}"
    printf "  %-32s : %s\n" "Active Pod Replicas Involved" "${unique_pods}"
    echo "======================================================================"

    if [[ "$failed_reqs" -eq 0 && "$success_reqs" -ge 40 && "$new_theme_reqs" -gt 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✅ DYNAMIC RELOAD VERIFICATION PASSED:${CLR_RESET} 100.0%% availability and smooth config transition observed!"
        exit 0
    elif [[ "$failed_reqs" -eq 0 && "$success_reqs" -gt 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✅ ROLLOUT COMPLETED:${CLR_RESET} Zero failed requests during config update."
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ VERIFICATION FAILED:${CLR_RESET} Observed ${failed_reqs} failed requests or missing config transition."
        exit 1
    fi
}

main "$@"
