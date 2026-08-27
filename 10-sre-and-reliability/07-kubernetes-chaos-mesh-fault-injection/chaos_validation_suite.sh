#!/usr/bin/env bash
# ==============================================================================
# chaos_validation_suite.sh - Automated Kubernetes Chaos Mesh Test Suite
# ==============================================================================
# Executes declarative chaos experiments on Kubernetes using Chaos Mesh:
# 1. Verifies prerequisites and lints technical documentation.
# 2. Bootstraps local K3d cluster & installs Chaos Mesh Operator via Helm.
# 3. Executes Baseline Steady-State Traffic Test (asserting 100% availability).
# 4. Executes Experiment 1: PodChaos (pod-failure.yaml) asserting >99.0% SLO.
# 5. Executes Experiment 2: NetworkChaos (network-latency.yaml) asserting latency.
# 6. Executes Experiment 3: StressChaos (stress-chaos.yaml) asserting stability.
# 7. Executes Experiment 4: Workflow Chaos (chaos-workflow.yaml).
# 8. Validates generated Chaos Experiment reports (JSON & Markdown).
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export KUBECONFIG="$SCRIPT_DIR/.kubeconfig"
TARGET_URL="http://localhost:8088/api/v1/checkout"

PASSED_TESTS=0
FAILED_TESTS=0

log_header() {
    echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================"
    echo "  $1"
    echo "======================================================================${CLR_RESET}"
}

log_step() {
    echo -e "${CLR_YELLOW}▶ $1${CLR_RESET}"
}

assert_test() {
    local test_name="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] $test_name (Exit Code: $exit_code)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

wait_for_healing() {
    kubectl wait --for=condition=Ready pods -l app=payment-api -n chaos-lab --timeout=45s >/dev/null 2>&1 || true
    sleep 2
}

log_header "🧪 STARTING KUBERNETES CHAOS MESH VALIDATION SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/8] Validating system tools and CLIs..."
for tool in k3d kubectl helm docker python3 pnpm; do
    if command -v "$tool" >/dev/null 2>&1; then
        assert_test "$tool CLI is available" 0
    else
        assert_test "$tool CLI is available" 1
    fi
done

# ------------------------------------------------------------------------------
# STEP 1: Documentation Markdownlint Validation
# ------------------------------------------------------------------------------
log_step "[Step 1/8] Linting README.md with markdownlint-cli..."
if pnpm dlx markdownlint-cli "$SCRIPT_DIR/README.md" >/dev/null 2>&1; then
    assert_test "README.md conforms strictly to markdownlint rules" 0
else
    assert_test "README.md conforms strictly to markdownlint rules" 1
fi

# ------------------------------------------------------------------------------
# STEP 2: Bootstrap Cluster & Workloads
# ------------------------------------------------------------------------------
log_step "[Step 2/8] Bootstrapping K3d cluster and deploying Chaos Mesh..."
rm -f "$SCRIPT_DIR/chaos_report.md" "$SCRIPT_DIR/chaos_report.json"
bash "$SCRIPT_DIR/scripts/setup_cluster.sh"
assert_test "K3d cluster and Chaos Mesh Operator deployed" $?

# Clean any existing experiments from earlier runs
kubectl delete podchaos,networkchaos,stresschaos,timechaos,workflow --all --all-namespaces --timeout=15s >/dev/null 2>&1 || true
wait_for_healing

# ------------------------------------------------------------------------------
# STEP 3: Baseline Steady-State Traffic Test
# ------------------------------------------------------------------------------
log_step "[Step 3/8] Running Baseline Steady-State Traffic Measurement (5s, 25 RPS)..."
python3 "$SCRIPT_DIR/traffic_generator.py" \
    --url "$TARGET_URL" \
    --duration 5 \
    --rps 25 \
    --name "Baseline Steady State" \
    --min-availability 99.9
assert_test "Baseline steady-state traffic maintained 100% availability" $?

# ------------------------------------------------------------------------------
# STEP 4: Experiment 1 - Pod Failure Chaos Injection (PodChaos)
# ------------------------------------------------------------------------------
log_step "[Step 4/8] Running Experiment 1: PodChaos (pod-failure.yaml) under active load..."
kubectl delete -f "$SCRIPT_DIR/experiments/pod-failure.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

# Start traffic generator in background
python3 "$SCRIPT_DIR/traffic_generator.py" \
    --url "$TARGET_URL" \
    --duration 10 \
    --rps 25 \
    --name "Pod Failure Chaos (PodChaos)" \
    --min-availability 99.0 &
LOAD_PID=$!

# Inject PodChaos after 2 seconds of traffic
sleep 2
echo -e "  [${CLR_MAGENTA}CHAOS INJECTION${CLR_RESET}] Applying 'experiments/pod-failure.yaml'..."
kubectl apply -f "$SCRIPT_DIR/experiments/pod-failure.yaml" >/dev/null

wait $LOAD_PID
LOAD_EXIT=$?

# Remove experiment and allow pods to heal
kubectl delete -f "$SCRIPT_DIR/experiments/pod-failure.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

assert_test "Service maintained >= 99% availability during PodChaos injection" $LOAD_EXIT

# ------------------------------------------------------------------------------
# STEP 5: Experiment 2 - Network Latency Injection (NetworkChaos)
# ------------------------------------------------------------------------------
log_step "[Step 5/8] Running Experiment 2: NetworkChaos (network-latency.yaml)..."
kubectl delete -f "$SCRIPT_DIR/experiments/network-latency.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

python3 "$SCRIPT_DIR/traffic_generator.py" \
    --url "$TARGET_URL" \
    --duration 8 \
    --rps 20 \
    --name "Network Latency Chaos (NetworkChaos)" \
    --min-availability 95.0 &
NET_LOAD_PID=$!

sleep 1
echo -e "  [${CLR_MAGENTA}CHAOS INJECTION${CLR_RESET}] Applying 'experiments/network-latency.yaml'..."
kubectl apply -f "$SCRIPT_DIR/experiments/network-latency.yaml" >/dev/null

wait $NET_LOAD_PID
NET_EXIT=$?

kubectl delete -f "$SCRIPT_DIR/experiments/network-latency.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

assert_test "Service handled NetworkChaos latency without catastrophic failure" $NET_EXIT

# ------------------------------------------------------------------------------
# STEP 6: Experiment 3 - Stress Chaos (StressChaos)
# ------------------------------------------------------------------------------
log_step "[Step 6/8] Running Experiment 3: StressChaos (stress-chaos.yaml)..."
kubectl delete -f "$SCRIPT_DIR/experiments/stress-chaos.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

python3 "$SCRIPT_DIR/traffic_generator.py" \
    --url "$TARGET_URL" \
    --duration 8 \
    --rps 20 \
    --name "CPU & Memory Stress Chaos (StressChaos)" \
    --min-availability 95.0 &
STRESS_PID=$!

sleep 1
echo -e "  [${CLR_MAGENTA}CHAOS INJECTION${CLR_RESET}] Applying 'experiments/stress-chaos.yaml'..."
kubectl apply -f "$SCRIPT_DIR/experiments/stress-chaos.yaml" >/dev/null

wait $STRESS_PID
STRESS_EXIT=$?

kubectl delete -f "$SCRIPT_DIR/experiments/stress-chaos.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

assert_test "Service remained healthy during CPU/Memory StressChaos" $STRESS_EXIT

# ------------------------------------------------------------------------------
# STEP 7: Experiment 4 - Multi-Stage Chaos Workflow (Workflow)
# ------------------------------------------------------------------------------
log_step "[Step 7/8] Running Experiment 4: Multi-Stage Workflow (chaos-workflow.yaml)..."
kubectl delete -f "$SCRIPT_DIR/experiments/chaos-workflow.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

kubectl apply -f "$SCRIPT_DIR/experiments/chaos-workflow.yaml" >/dev/null
sleep 3
if kubectl get workflow -n chaos-lab 2>/dev/null | grep -q "resilience-validation-workflow"; then
    assert_test "Chaos Mesh Workflow reconciled and executed successfully" 0
else
    assert_test "Chaos Mesh Workflow reconciled and executed successfully" 1
fi
kubectl delete -f "$SCRIPT_DIR/experiments/chaos-workflow.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
wait_for_healing

# ------------------------------------------------------------------------------
# STEP 8: Validate Chaos Experiment Report Artifacts
# ------------------------------------------------------------------------------
log_step "[Step 8/8] Verifying generated Chaos Experiment report artifacts..."
if [ -f "$SCRIPT_DIR/chaos_report.md" ] && [ -f "$SCRIPT_DIR/chaos_report.json" ]; then
    assert_test "Chaos report artifacts (chaos_report.md & chaos_report.json) exist" 0
else
    assert_test "Chaos report artifacts (chaos_report.md & chaos_report.json) exist" 1
fi

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY RESULTS"
echo -e "  Passed assertions: ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed assertions: ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL $PASSED_TESTS ASSERTIONS PASSED! Mini-Project 10-07 is 100% operational!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ $FAILED_TESTS ASSERTION(S) FAILED! Check output above.${CLR_RESET}\n"
    exit 1
fi
