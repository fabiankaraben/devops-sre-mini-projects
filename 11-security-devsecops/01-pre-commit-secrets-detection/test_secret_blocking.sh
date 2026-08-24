#!/usr/bin/env bash
# ==============================================================================
# test_secret_blocking.sh - Automated E2E Test Suite for Pre-Commit Secrets Suite
# ==============================================================================
# Verifies complete Git pre-commit secrets blocking lifecycle:
# 1. Validates environment dependencies (git, python3, pre-commit, gitleaks, detect-secrets).
# 2. Creates an isolated ephemeral Git repository sandbox (.test_sandbox/sandbox_repo).
# 3. Installs pre-commit git hooks in the sandbox repository.
# 4. Stages clean source code and verifies commits PASS without warnings.
# 5. Stages mock credentials (AWS, GitHub, RSA, Slack, JWT) and verifies commits are BLOCKED.
# 6. Stages allowlisted mock token and verifies allowlist exceptions PASS.
# 7. Executes direct Gitleaks and detect-secrets CLI scans against test fixtures.
# 8. Validates Python Shannon entropy analytics and report generation (secrets_analyzer.py).
# 9. Cleans up ephemeral sandbox directories.
# ==============================================================================

set -euo pipefail

# ANSI Colors
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

SANDBOX_DIR="$SCRIPT_DIR/.test_sandbox"
REPO_DIR="$SANDBOX_DIR/sandbox_repo"

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

cleanup_sandbox() {
    if [ -d "$SANDBOX_DIR" ]; then
        rm -rf "$SANDBOX_DIR"
    fi
    rm -f "$SCRIPT_DIR/secrets_report.json" "$SCRIPT_DIR/audit_output.txt"
}

trap cleanup_sandbox EXIT

log_header "🧪 STARTING PRE-COMMIT GIT SECRETS DETECTION TEST SUITE"

# ------------------------------------------------------------------------------
# STEP 0: System Prerequisites Validation
# ------------------------------------------------------------------------------
log_step "[Step 0/7] Checking environment dependencies..."

if command -v git >/dev/null 2>&1; then
    assert_test "git CLI is installed" 0
else
    assert_test "git CLI is installed" 1
fi

if command -v python3 >/dev/null 2>&1; then
    assert_test "python3 is installed" 0
else
    assert_test "python3 is installed" 1
fi

if command -v gitleaks >/dev/null 2>&1; then
    assert_test "gitleaks CLI is installed ($(gitleaks version 2>/dev/null || echo 'detected'))" 0
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] gitleaks binary not in PATH (will test via pre-commit / Docker)"
fi

if command -v detect-secrets >/dev/null 2>&1; then
    assert_test "detect-secrets CLI is installed" 0
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] detect-secrets not in PATH (will test via pre-commit / Docker)"
fi

if command -v pre-commit >/dev/null 2>&1; then
    assert_test "pre-commit framework is installed" 0
else
    assert_test "pre-commit framework is installed" 1
fi

# ------------------------------------------------------------------------------
# STEP 1: Ephemeral Sandbox Initialization
# ------------------------------------------------------------------------------
log_step "[Step 1/7] Creating isolated ephemeral Git sandbox..."
cleanup_sandbox
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

git init -q
git config user.name "DevSecOps Sandbox Tester"
git config user.email "sandbox-tester@internal.test"
git config commit.gpgsign false

# Copy configuration files into sandbox repo
cp "$SCRIPT_DIR/.pre-commit-config.yaml" "$REPO_DIR/"
cp "$SCRIPT_DIR/.gitleaks.toml" "$REPO_DIR/"
cp "$SCRIPT_DIR/.secrets.baseline" "$REPO_DIR/"

assert_test "Ephemeral sandbox Git repository initialized" 0

# ------------------------------------------------------------------------------
# STEP 2: Stage & Commit Clean Code
# ------------------------------------------------------------------------------
log_step "[Step 2/7] Testing Clean Code Commits (Expecting SUCCESS)..."

mkdir -p "$REPO_DIR/src"
cp -r "$SCRIPT_DIR/test_fixtures/clean_code/"* "$REPO_DIR/src/"

git add .pre-commit-config.yaml .gitleaks.toml .secrets.baseline src/

# Run pre-commit hook against staged files
if pre-commit run --all-files >/dev/null 2>&1; then
    assert_test "Pre-commit hooks pass on clean application code" 0
else
    # In some environments first run installs environments; retry run
    if pre-commit run --all-files >/dev/null 2>&1; then
        assert_test "Pre-commit hooks pass on clean application code" 0
    else
        assert_test "Pre-commit hooks pass on clean application code" 1
    fi
fi

# Perform actual Git commit in sandbox
if git commit -m "feat: initial clean release" >/dev/null 2>&1; then
    assert_test "Git commit successfully created for clean code" 0
else
    assert_test "Git commit successfully created for clean code" 1
fi

# ------------------------------------------------------------------------------
# STEP 3: Stage Mock Secrets & Verify Commit Interception / Blocking
# ------------------------------------------------------------------------------
log_step "[Step 3/7] Testing Secret Blocking on Staged Leaks (Expecting BLOCKED / NON-ZERO)..."

test_secret_block() {
    local fixture_name="$1"
    local file_path="$2"
    local dest_name="$3"

    cp "$file_path" "$REPO_DIR/$dest_name"
    git add "$dest_name"

    local blocked=0
    if pre-commit run --files "$dest_name" >/dev/null 2>&1; then
        # If pre-commit passed, it failed to detect the secret!
        blocked=1
    else
        # Hook blocked it!
        blocked=0
    fi

    # Unstage and remove test file to keep sandbox clean for next test
    git reset -q "$dest_name" >/dev/null 2>&1 || true
    rm -f "$REPO_DIR/$dest_name"

    assert_test "Pre-commit blocked $fixture_name" "$blocked"
}

test_secret_block "AWS Credentials Leak (AKIA & Secret Key)" \
    "$SCRIPT_DIR/test_fixtures/mock_secrets/aws_credentials.env" "aws_credentials.env"

test_secret_block "GitHub Personal Access Token (ghp_...)" \
    "$SCRIPT_DIR/test_fixtures/mock_secrets/github_token.py" "github_token.py"

test_secret_block "RSA Private Cryptographic Key (PEM Block)" \
    "$SCRIPT_DIR/test_fixtures/mock_secrets/private_key.pem" "private_key.pem"

test_secret_block "Slack Incoming Webhook URL" \
    "$SCRIPT_DIR/test_fixtures/mock_secrets/slack_webhook.json" "slack_webhook.json"

test_secret_block "Hardcoded JWT Signing Secret" \
    "$SCRIPT_DIR/test_fixtures/mock_secrets/jwt_secret.js" "jwt_secret.js"

# ------------------------------------------------------------------------------
# STEP 4: Test Allowlisted Token Exceptions
# ------------------------------------------------------------------------------
log_step "[Step 4/7] Testing Allowlist & Baseline Exceptions (Expecting PASS)..."

mkdir -p "$REPO_DIR/test_fixtures/mock_secrets"
cp "$SCRIPT_DIR/test_fixtures/mock_secrets/allowlisted_mock_token.py" "$REPO_DIR/test_fixtures/mock_secrets/"
git add "test_fixtures/mock_secrets/allowlisted_mock_token.py"

if pre-commit run --files "test_fixtures/mock_secrets/allowlisted_mock_token.py" >/dev/null 2>&1; then
    assert_test "Allowlisted mock token is permitted by policy" 0
else
    # Allowlist check
    assert_test "Allowlisted mock token is permitted by policy" 1
fi

git reset -q "test_fixtures/mock_secrets/allowlisted_mock_token.py" >/dev/null 2>&1 || true
rm -rf "$REPO_DIR/test_fixtures"

# ------------------------------------------------------------------------------
# STEP 5: Direct Gitleaks Engine Scan
# ------------------------------------------------------------------------------
log_step "[Step 5/7] Testing Direct Gitleaks Scanner against Mock Fixtures..."
cd "$SCRIPT_DIR"

if command -v gitleaks >/dev/null 2>&1; then
    # gitleaks detect on directory with no git history (directory mode)
    if gitleaks dir --config="$SCRIPT_DIR/.gitleaks.toml" --verbose "$SCRIPT_DIR/test_fixtures/mock_secrets" >/dev/null 2>&1; then
        # If exit code is 0, gitleaks did not find secrets (failure for mock secrets directory)
        assert_test "Direct Gitleaks scanner flags mock secrets directory" 1
    else
        # Exit code != 0 indicates secrets detected!
        assert_test "Direct Gitleaks scanner flags mock secrets directory" 0
    fi
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] Skipping direct gitleaks CLI invocation (tested via pre-commit)"
fi

# ------------------------------------------------------------------------------
# STEP 6: Direct detect-secrets Baseline Scan
# ------------------------------------------------------------------------------
log_step "[Step 6/7] Testing detect-secrets Baseline Scanning..."

if command -v detect-secrets >/dev/null 2>&1; then
    if detect-secrets scan "$SCRIPT_DIR/test_fixtures/clean_code" > "$SCRIPT_DIR/audit_output.txt" 2>&1; then
        assert_test "detect-secrets scan executed successfully on clean fixtures" 0
    else
        assert_test "detect-secrets scan executed successfully on clean fixtures" 1
    fi
    rm -f "$SCRIPT_DIR/audit_output.txt"
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] Skipping direct detect-secrets invocation"
fi

# ------------------------------------------------------------------------------
# STEP 7: Python Entropy & Analytics Engine (secrets_analyzer.py)
# ------------------------------------------------------------------------------
log_step "[Step 7/7] Validating secrets_analyzer.py CLI and JSON Report..."

# Test 1: Clean code scan
if python3 "$SCRIPT_DIR/secrets_analyzer.py" --scan-dir "$SCRIPT_DIR/test_fixtures/clean_code" --strict >/dev/null 2>&1; then
    assert_test "secrets_analyzer.py passes clean code in strict mode" 0
else
    assert_test "secrets_analyzer.py passes clean code in strict mode" 1
fi

# Test 2: Mock secrets scan with JSON export
if python3 "$SCRIPT_DIR/secrets_analyzer.py" --scan-dir "$SCRIPT_DIR/test_fixtures/mock_secrets" --json-out "$SCRIPT_DIR/secrets_report.json" >/dev/null 2>&1; then
    if [ -f "$SCRIPT_DIR/secrets_report.json" ]; then
        assert_test "secrets_analyzer.py discovers secrets and exports JSON report" 0
    else
        assert_test "secrets_analyzer.py discovers secrets and exports JSON report" 1
    fi
else
    assert_test "secrets_analyzer.py discovers secrets and exports JSON report" 1
fi

# Test 3: Shannon Entropy calculation CLI
ENTROPY_OUT=$(python3 "$SCRIPT_DIR/secrets_analyzer.py" --calc-entropy "wJalrXUtnFEMI/K7MDENG/bPxRfiCYINVALIDKEY99" | grep "Shannon Entropy" || true)
if [[ "$ENTROPY_OUT" =~ "Shannon Entropy" ]]; then
    assert_test "Shannon entropy calculation verified: $ENTROPY_OUT" 0
else
    assert_test "Shannon entropy calculation verified" 1
fi

# ------------------------------------------------------------------------------
# FINAL TEST SUITE RESULTS
# ------------------------------------------------------------------------------
log_header "📊 TEST SUITE SUMMARY"
echo -e "  Total Tests Evaluated : $((PASSED_TESTS + FAILED_TESTS))"
echo -e "  Passed                : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed                : ${CLR_RED}${FAILED_TESTS}${CLR_RESET}"
echo "======================================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 ALL PRE-COMMIT GIT SECRETS TESTS PASSED SUCCESSFULLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}❌ SOME TESTS FAILED. CHECK LOGS ABOVE.${CLR_RESET}\n"
    exit 1
fi
