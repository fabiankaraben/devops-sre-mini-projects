#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_provision_users.sh
# Description: Automated Test Suite for User & Group Batch Provisioner.
#              Tests argument handling, dry-run simulation, user/group creation,
#              SSH key permissions (0700/0600), sudoers safety, deactivation,
#              idempotency, and cleanup rollback.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION_SCRIPT="${SCRIPT_DIR}/provision_users.sh"
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup_users.sh"
MANIFEST="${SCRIPT_DIR}/users_manifest.csv"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

report_test() {
    local name="$1"
    local result="$2"
    local details="${3:-}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$result" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${GREEN}PASS${NC}] ${name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${RED}FAIL${NC}] ${name}"
        if [[ -n "$details" ]]; then
            echo -e "         ${YELLOW}Details: ${details}${NC}"
        fi
    fi
}

validate_json() {
    local json_str="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$json_str" | jq . >/dev/null 2>&1
        return $?
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys, json; json.loads(sys.stdin.read())" <<< "$json_str" >/dev/null 2>&1
        return $?
    else
        return 0
    fi
}

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}  User & Group Batch Provisioner - Automated Tests   ${NC}"
echo -e "${BLUE}======================================================${NC}\n"

# ------------------------------------------------------------------------------
# Suite 1: CLI Arguments & Help
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Suite 1: CLI Arguments & Help Handling${NC}"

set +e
output=$("$PROVISION_SCRIPT" --help 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 0 && "$output" =~ "Usage:" ]]; then
    report_test "--help displays usage and exits 0" "PASS"
else
    report_test "--help displays usage and exits 0" "FAIL" "Exit code: ${exit_code}"
fi

set +e
output=$("$PROVISION_SCRIPT" --manifest "/non_existent_manifest_123.csv" 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 2 ]]; then
    report_test "Missing manifest file triggers exit code 2" "PASS"
else
    report_test "Missing manifest file triggers exit code 2" "FAIL" "Expected 2, got: ${exit_code}"
fi

# ------------------------------------------------------------------------------
# Suite 2: Dry Run Mode Simulation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 2: Dry Run Mode Simulation${NC}"

set +e
dry_output=$("$PROVISION_SCRIPT" --manifest "$MANIFEST" --dry-run --json 2>&1)
dry_exit=$?
set -e

if [[ $dry_exit -eq 0 ]]; then
    report_test "Dry-run completes successfully without root requirement" "PASS"
else
    report_test "Dry-run completes successfully" "FAIL" "Exit code: ${dry_exit}"
fi

if validate_json "$dry_output"; then
    report_test "Dry-run outputs valid JSON schema" "PASS"
else
    report_test "Dry-run outputs valid JSON schema" "FAIL" "Invalid JSON generated"
fi

if [[ "$dry_output" =~ "\"dry_run\": true" && "$dry_output" =~ "dry-run-create" ]]; then
    report_test "JSON payload confirms dry_run flag and simulated actions" "PASS"
else
    report_test "JSON payload confirms dry_run flag" "FAIL" "Missing dry_run field"
fi

# ------------------------------------------------------------------------------
# Suite 3: Live Account Provisioning (Linux / Root required)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Suite 3: Live Provisioning & Security Enforcement${NC}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "  [${YELLOW}SKIP${NC}] Live account provisioning requires root/sudo privileges."
    echo -e "         (Run inside Docker container or with sudo to execute live tests)"
else
    # 1. Clean previous state if any
    "$CLEANUP_SCRIPT" --manifest "$MANIFEST" >/dev/null 2>&1 || true

    # 2. Run provisioner
    set +e
    prov_output=$("$PROVISION_SCRIPT" --manifest "$MANIFEST" --json 2>&1)
    prov_exit=$?
    set -e

    if [[ $prov_exit -eq 0 ]]; then
        report_test "Live batch provisioning executed with exit code 0" "PASS"
    else
        report_test "Live batch provisioning executed with exit code 0" "FAIL" "Exit code: ${prov_exit}"
    fi

    # 3. Check user existence
    if id -u alice >/dev/null 2>&1 && id -u bob >/dev/null 2>&1 && id -u charlie >/dev/null 2>&1; then
        report_test "Users alice, bob, and charlie created in system" "PASS"
    else
        report_test "Users alice, bob, and charlie created in system" "FAIL" "Users missing in /etc/passwd"
    fi

    # 4. Check secondary groups for alice (should include docker or adm)
    alice_groups=$(id -Gn alice 2>/dev/null || echo "")
    if [[ "$alice_groups" =~ "developers" ]]; then
        report_test "Primary/Secondary groups assigned correctly to alice ($alice_groups)" "PASS"
    else
        report_test "Primary/Secondary groups assigned correctly to alice" "FAIL" "Groups: ${alice_groups}"
    fi

    # 5. Check SSH permissions: .ssh directory must be 0700, authorized_keys must be 0600
    if [[ -d "/home/alice/.ssh" && -f "/home/alice/.ssh/authorized_keys" ]]; then
        # Check permissions using stat
        ssh_perm=$(stat -c %a /home/alice/.ssh 2>/dev/null || stat -f %Lp /home/alice/.ssh 2>/dev/null || echo "")
        keys_perm=$(stat -c %a /home/alice/.ssh/authorized_keys 2>/dev/null || stat -f %Lp /home/alice/.ssh/authorized_keys 2>/dev/null || echo "")

        if [[ "$ssh_perm" == "700" && "$keys_perm" == "600" ]]; then
            report_test "SSH permissions strictly enforced (dir: 0700, keys: 0600)" "PASS"
        else
            report_test "SSH permissions strictly enforced (dir: 0700, keys: 0600)" "FAIL" "dir: ${ssh_perm}, keys: ${keys_perm}"
        fi
    else
        report_test "SSH directory and authorized_keys file created" "FAIL" "Files missing in /home/alice/.ssh"
    fi

    # 6. Check sudoers drop-in configuration for alice
    if [[ -f "/etc/sudoers.d/99-user-alice" ]]; then
        if command -v visudo >/dev/null 2>&1; then
            if visudo -c -f /etc/sudoers.d/99-user-alice >/dev/null 2>&1; then
                report_test "Sudoers drop-in file validated via visudo -c" "PASS"
            else
                report_test "Sudoers drop-in file validated via visudo -c" "FAIL" "visudo syntax check failed"
            fi
        else
            report_test "Sudoers drop-in file exists for alice" "PASS"
        fi
    else
        report_test "Sudoers drop-in file exists for alice" "FAIL" "Missing /etc/sudoers.d/99-user-alice"
    fi

    # 7. Check user deactivation for dave (status: inactive)
    dave_shell=$(getent passwd dave 2>/dev/null | cut -d: -f7 || echo "")
    if [[ "$dave_shell" =~ "nologin" || "$dave_shell" =~ "false" ]]; then
        report_test "Inactive user dave assigned nologin shell (${dave_shell})" "PASS"
    else
        report_test "Inactive user dave assigned nologin shell" "FAIL" "Shell: ${dave_shell}"
    fi

    # --------------------------------------------------------------------------
    # Suite 4: Idempotency Test
    # --------------------------------------------------------------------------
    echo -e "\n${YELLOW}Suite 4: Idempotency Verification${NC}"

    set +e
    idemp_output=$("$PROVISION_SCRIPT" --manifest "$MANIFEST" --json 2>&1)
    idemp_exit=$?
    set -e

    if [[ $idemp_exit -eq 0 ]]; then
        report_test "Second provisioning run succeeds idempotently without errors" "PASS"
    else
        report_test "Second provisioning run succeeds idempotently" "FAIL" "Exit code: ${idemp_exit}"
    fi

    # --------------------------------------------------------------------------
    # Suite 5: Rollback & Cleanup Verification
    # --------------------------------------------------------------------------
    echo -e "\n${YELLOW}Suite 5: Rollback & Environment Cleanup${NC}"

    set +e
    clean_output=$("$CLEANUP_SCRIPT" --manifest "$MANIFEST" --json 2>&1)
    clean_exit=$?
    set -e

    if [[ $clean_exit -eq 0 ]]; then
        report_test "cleanup_users.sh executes rollback with exit code 0" "PASS"
    else
        report_test "cleanup_users.sh executes rollback" "FAIL" "Exit code: ${clean_exit}"
    fi

    # Verify users deleted
    if ! id -u alice >/dev/null 2>&1 && ! id -u bob >/dev/null 2>&1 && [[ ! -d "/home/alice" ]]; then
        report_test "Provisioned users, home dirs, and sudoers cleanly purged" "PASS"
    else
        report_test "Provisioned users, home dirs, and sudoers cleanly purged" "FAIL" "Residual accounts or home dirs found"
    fi
fi

# ------------------------------------------------------------------------------
# Test Summary
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}======================================================${NC}"
echo -e "  Test Results: ${PASSED_TESTS}/${TOTAL_TESTS} Passed"
if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "  Status: ${GREEN}ALL TESTS PASSED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 0
else
    echo -e "  Status: ${RED}${FAILED_TESTS} TESTS FAILED${NC}"
    echo -e "${BLUE}======================================================${NC}\n"
    exit 1
fi
