#!/usr/bin/env bash
# ==============================================================================
# test_stack.sh - SRE Incident Postmortem Generator End-to-End Validation
# ==============================================================================
# 1. Verifies prerequisites and lints technical documentation.
# 2. Runs Python test suite (unit tests, timeline sorting, metrics math).
# 3. Executes CLI generator for INC-402, INC-501, and INC-305.
# 4. Validates generated Markdown postmortems with markdownlint.
# 5. Tests Docker containerized build and execution via Docker Compose.
# 6. Verifies report output artifacts and prints summary.
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

log_header "🧪 STARTING SRE POSTMORTEM GENERATOR VALIDATION SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/6] Checking system tools..."
for tool in python3 docker pnpm; do
    if command -v "$tool" >/dev/null 2>&1; then
        assert_test "$tool is available" 0
    else
        assert_test "$tool is available" 1
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
# STEP 2: Python Unit & Timeline Validation Suite
# ------------------------------------------------------------------------------
log_step "[Step 2/6] Executing Python test suite (test_generator.py)..."
python3 "$SCRIPT_DIR/test_generator.py"
assert_test "Python test suite passed all timeline and SRE metrics tests" $?

# ------------------------------------------------------------------------------
# STEP 3: Multi-Incident Generation (INC-402, INC-501, INC-305)
# ------------------------------------------------------------------------------
log_step "[Step 3/6] Generating postmortem reports across multiple incident fixtures..."
rm -rf "$SCRIPT_DIR/reports"
mkdir -p "$SCRIPT_DIR/reports"

for inc in INC-402 INC-501 INC-305; do
    python3 "$SCRIPT_DIR/postmortem_generator.py" --incident-id "$inc" --format all --output-dir "$SCRIPT_DIR/reports" >/dev/null
    assert_test "Postmortem generated for $inc (Markdown, JSON, HTML)" $?
done

# ------------------------------------------------------------------------------
# STEP 4: Validate Generated Markdown Postmortems with Markdownlint
# ------------------------------------------------------------------------------
log_step "[Step 4/6] Linting generated Markdown postmortems with markdownlint-cli..."
if pnpm dlx markdownlint-cli "$SCRIPT_DIR/reports"/*.md >/dev/null 2>&1; then
    assert_test "All generated Postmortem Markdown reports pass markdownlint" 0
else
    assert_test "All generated Postmortem Markdown reports pass markdownlint" 1
fi

# ------------------------------------------------------------------------------
# STEP 5: Docker Containerized Build & Execution
# ------------------------------------------------------------------------------
log_step "[Step 5/6] Building and running Docker containerized postmortem generator..."
docker compose build >/dev/null 2>&1
assert_test "Docker image 'sre-incident-postmortem-generator' built successfully" $?

rm -rf "$SCRIPT_DIR/reports/docker_run"
docker compose run --rm postmortem-generator --incident-id INC-402 --format all --output-dir /app/reports/docker_run >/dev/null 2>&1
assert_test "Docker container ran successfully and generated reports" $?

# ------------------------------------------------------------------------------
# STEP 6: Artifact Integrity & Metric Sanity Validation
# ------------------------------------------------------------------------------
log_step "[Step 6/6] Verifying generated report files..."
REPORT_COUNT=$(find "$SCRIPT_DIR/reports" -type f | wc -l | tr -d ' ')
if [ "$REPORT_COUNT" -ge 9 ]; then
    assert_test "Found $REPORT_COUNT generated report files (Markdown, JSON, HTML)" 0
else
    assert_test "Found $REPORT_COUNT generated report files (Expected >= 9)" 1
fi

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY RESULTS"
echo -e "  Passed assertions: ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed assertions: ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL $PASSED_TESTS ASSERTIONS PASSED! Mini-Project 10-08 is 100% operational!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ $FAILED_TESTS ASSERTION(S) FAILED! Check output above.${CLR_RESET}\n"
    exit 1
fi
