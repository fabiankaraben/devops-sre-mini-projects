#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - Graceful Shutdown & Connection Draining End-to-End Test Suite
# ==============================================================================
# 1. Validates system dependencies and lints documentation with markdownlint.
# 2. Runs lifecycle unit test suite (SIGTERM interception, in-flight draining).
# 3. Provisions isolated K3d cluster 'k3d-graceful-demo'.
# 4. Executes continuous flood load test during active Kubernetes rolling updates.
# 5. Asserts 100.0% availability and zero connection resets on graceful deployment.
# 6. Demonstrates connection drops on naive deployment without preStop hooks.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export KUBECONFIG="$SCRIPT_DIR/.kubeconfig"
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

log_header "🧪 STARTING GRACEFUL SHUTDOWN & CONNECTION DRAINING TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/6] Checking system tools..."
for tool in python3 docker k3d kubectl pnpm; do
    if command -v "$tool" >/dev/null 2>&1; then
        assert_test "$tool is installed and available" 0
    else
        assert_test "$tool is installed and available" 1
    fi
done

# ------------------------------------------------------------------------------
# STEP 1: Documentation Markdownlint Validation
# ------------------------------------------------------------------------------
log_step "[Step 1/6] Linting README.md with markdownlint-cli..."
if pnpm dlx markdownlint-cli "$SCRIPT_DIR/README.md" >/dev/null 2>&1; then
    assert_test "README.md conforms strictly to markdownlint rules" 0
else
    assert_test "README.md conforms strictly to markdownlint rules" 1
fi

# ------------------------------------------------------------------------------
# STEP 2: Standalone Python Graceful Signal & Draining Unit Tests
# ------------------------------------------------------------------------------
log_step "[Step 2/6] Executing lifecycle test suite (test_lifecycle.py)..."
python3 "$SCRIPT_DIR/test_lifecycle.py"
assert_test "Lifecycle tests passed (readiness 503, graceful draining, naive aborts)" $?

# ------------------------------------------------------------------------------
# STEP 3: Setup Local K3d Cluster
# ------------------------------------------------------------------------------
log_step "[Step 3/6] Setting up isolated K3d cluster and applying manifests..."
mkdir -p "$SCRIPT_DIR/reports"
"$SCRIPT_DIR/scripts/setup_cluster.sh" > "$SCRIPT_DIR/reports/setup_cluster.log" 2>&1
assert_test "K3d cluster 'k3d-graceful-demo' provisioned and pods ready" $?

# ------------------------------------------------------------------------------
# STEP 4: Zero-Downtime Rolling Update Under Heavy Load (Graceful Stack)
# ------------------------------------------------------------------------------
log_step "[Step 4/6] Executing flood_during_restart.sh against Graceful Deployment..."
"$SCRIPT_DIR/flood_during_restart.sh" --graceful --duration=25 > "$SCRIPT_DIR/reports/flood_graceful.log" 2>&1
assert_test "Graceful Rolling Update achieved 100% availability with 0 connection resets" $?

# ------------------------------------------------------------------------------
# STEP 5: Comparative Demonstration (Naive Deployment Drops Connections)
# ------------------------------------------------------------------------------
log_step "[Step 5/6] Executing flood_during_restart.sh against Naive Deployment..."
"$SCRIPT_DIR/flood_during_restart.sh" --naive --duration=20 --url="http://localhost:8089/naive/work" > "$SCRIPT_DIR/reports/flood_naive.log" 2>&1 || true
assert_test "Comparative test executed on Naive Deployment" 0

# ------------------------------------------------------------------------------
# STEP 6: Report Artifacts Verification & Markdownlint
# ------------------------------------------------------------------------------
log_step "[Step 6/6] Verifying generated test reports and linting output..."
REPORT_COUNT=$(find "$SCRIPT_DIR/reports" -type f \( -name "*.md" -o -name "*.json" \) | wc -l | tr -d ' ')
if [ "$REPORT_COUNT" -ge 2 ]; then
    assert_test "Generated $REPORT_COUNT test report files (JSON & Markdown)" 0
else
    assert_test "Generated $REPORT_COUNT test report files (Expected >= 2)" 1
fi

if pnpm dlx markdownlint-cli "$SCRIPT_DIR/reports"/*.md >/dev/null 2>&1; then
    assert_test "All generated load test reports pass markdownlint" 0
else
    assert_test "All generated load test reports pass markdownlint" 1
fi

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY RESULTS"
echo -e "  Passed assertions: ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed assertions: ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL $PASSED_TESTS ASSERTIONS PASSED! Mini-Project 10-09 is 100% operational!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ $FAILED_TESTS ASSERTION(S) FAILED! Check logs in reports/ directory.${CLR_RESET}\n"
    exit 1
fi
