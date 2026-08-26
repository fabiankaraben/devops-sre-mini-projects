#!/usr/bin/env bash
# ==============================================================================
# verify_isolation.sh - Rootless Container Security & UID Isolation Auditor
# ==============================================================================
# Audits:
#   1. User Namespace UID mapping (/proc/self/uid_map)
#   2. GID mapping (/proc/self/gid_map)
#   3. PID namespace segregation (PID 1 convergence)
#   4. Host root filesystem read privilege boundary (/root/secret)
#   5. Host root filesystem write privilege boundary
#   6. Kernel sysctl parameter modification protection (/proc/sys)
#   7. Block device node creation restriction (mknod)
#   8. Kernel module manipulation restriction (modprobe)
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🔍 Rootless Container Security & User Namespace Isolation Audit"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

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

run_audit() {
    print_banner
    echo -e "${CLR_BOLD}👤 Parent Process Context:${CLR_RESET}"
    echo -e "  • Outside User:        $(whoami) (UID: $(id -u), GID: $(id -g))"
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

    # --------------------------------------------------------------------------
    # Test 1: User Namespace UID Mapping Verification
    # --------------------------------------------------------------------------
    local uid_map_output
    uid_map_output=$(unshare -U -r /bin/bash -c 'cat /proc/self/uid_map' 2>/dev/null || echo "")

    if [[ -n "$uid_map_output" ]]; then
        local inside_uid host_uid map_len
        read -r inside_uid host_uid map_len <<< "$uid_map_output"
        if [[ "$inside_uid" == "0" && "$host_uid" == "1000" ]]; then
            record_result "01" "User Namespace UID Mapping" 0 "Mapped Inside UID 0 -> Host UID 1000 (Length: ${map_len})"
        else
            record_result "01" "User Namespace UID Mapping" 1 "Unexpected mapping: ${uid_map_output}"
        fi
    else
        record_result "01" "User Namespace UID Mapping" 1 "Failed to read /proc/self/uid_map"
    fi

    # --------------------------------------------------------------------------
    # Test 2: User Namespace GID Mapping Verification
    # --------------------------------------------------------------------------
    local gid_map_output
    gid_map_output=$(unshare -U -r /bin/bash -c 'cat /proc/self/gid_map' 2>/dev/null || echo "")

    if [[ -n "$gid_map_output" ]]; then
        local inside_gid host_gid gid_len
        read -r inside_gid host_gid gid_len <<< "$gid_map_output"
        if [[ "$inside_gid" == "0" && "$host_gid" == "1000" ]]; then
            record_result "02" "User Namespace GID Mapping" 0 "Mapped Inside GID 0 -> Host GID 1000 (Length: ${gid_len})"
        else
            record_result "02" "User Namespace GID Mapping" 1 "Unexpected mapping: ${gid_map_output}"
        fi
    else
        record_result "02" "User Namespace GID Mapping" 1 "Failed to read /proc/self/gid_map"
    fi

    # --------------------------------------------------------------------------
    # Test 3: PID Namespace Isolation
    # --------------------------------------------------------------------------
    local pid_inside
    pid_inside=$(unshare -U -r -p --fork /bin/bash -c 'echo $$' 2>/dev/null || echo "")
    if [[ "$pid_inside" == "1" ]]; then
        record_result "03" "PID Namespace Segregation" 0 "Process converged as PID 1 inside new namespace"
    else
        record_result "03" "PID Namespace Segregation" 1 "Expected PID 1, got ${pid_inside}"
    fi

    # --------------------------------------------------------------------------
    # Test 4: Host Root Filesystem Read Protection
    # --------------------------------------------------------------------------
    # Inside the rootless namespace, UID 0 attempts to read a host root-owned file
    local read_attempt
    read_attempt=$(unshare -U -r /bin/bash -c 'cat /root/secret/flag.txt' 2>&1 || true)
    if echo "$read_attempt" | grep -qi "permission denied"; then
        record_result "04" "Host Root File Read Protection" 0 "cat /root/secret/flag.txt blocked: Permission Denied"
    else
        record_result "04" "Host Root File Read Protection" 1 "Security breach: Root file was readable! (${read_attempt})"
    fi

    # --------------------------------------------------------------------------
    # Test 5: Host Root Filesystem Write Protection
    # --------------------------------------------------------------------------
    local write_attempt
    write_attempt=$(unshare -U -r /bin/bash -c 'touch /root/secret/hacked.txt' 2>&1 || true)
    if echo "$write_attempt" | grep -qi "permission denied"; then
        record_result "05" "Host Root File Write Protection" 0 "touch /root/secret/hacked.txt blocked: Permission Denied"
    else
        record_result "05" "Host Root File Write Protection" 1 "Security breach: Root directory write permitted!"
    fi

    # --------------------------------------------------------------------------
    # Test 6: Kernel Parameters Protection (/proc/sys)
    # --------------------------------------------------------------------------
    local sysctl_attempt
    sysctl_attempt=$(unshare -U -r /bin/bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward' 2>&1 || true)
    if echo "$sysctl_attempt" | grep -Eqi "(permission denied|read-only)"; then
        record_result "06" "Kernel Sysctl Modification Protection" 0 "Write to /proc/sys/ blocked (Read-only / Permission Denied)"
    else
        record_result "06" "Kernel Sysctl Modification Protection" 1 "Unexpected result: ${sysctl_attempt}"
    fi

    # --------------------------------------------------------------------------
    # Test 7: Block Device Node Creation Restriction (mknod)
    # --------------------------------------------------------------------------
    local mknod_attempt
    mknod_attempt=$(unshare -U -r /bin/bash -c 'mknod /tmp/fake_disk b 8 0' 2>&1 || true)
    if echo "$mknod_attempt" | grep -qi "operation not permitted"; then
        record_result "07" "Raw Block Device Creation Restriction" 0 "mknod b 8 0 blocked: Operation not permitted"
    else
        record_result "07" "Raw Block Device Creation Restriction" 1 "Unexpected result: ${mknod_attempt}"
    fi

    # --------------------------------------------------------------------------
    # Test 8: Kernel Module Loading Restriction (modprobe)
    # --------------------------------------------------------------------------
    local modprobe_attempt
    modprobe_attempt=$(unshare -U -r /bin/bash -c 'modprobe dummy' 2>&1 || true)
    if echo "$modprobe_attempt" | grep -Eqi "(operation not permitted|permission denied|no such file|failed|not allowed)"; then
        record_result "08" "Kernel Module Loading Restriction" 0 "modprobe correctly restricted inside unprivileged user namespace"
    else
        record_result "08" "Kernel Module Loading Restriction" 1 "Unexpected result: ${modprobe_attempt}"
    fi

    # --------------------------------------------------------------------------
    # Audit Summary
    # --------------------------------------------------------------------------
    echo ""
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}  📊 Security Audit Summary: ${PASSED_TESTS}/${TOTAL_TESTS} Checks Passed${CLR_RESET}"
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✨ Rootless container isolation verified! Host privilege escalation is completely mitigated.${CLR_RESET}"
        return 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ Some isolation tests failed. Inspect the logs above.${CLR_RESET}"
        return 1
    fi
}

run_audit
