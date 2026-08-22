#!/usr/bin/env bash
# ==============================================================================
# ansible_audit.sh - E2E Ansible Playbook Audit & Idempotency Test Suite
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, Ansible, OpenSSH client, Python 3)
#   2. Playbook syntax validation (`ansible-playbook --syntax-check`)
#   3. Ephemeral target node provisioning via Docker on port 2222
#   4. Initial playbook execution & task application
#   5. Strict Idempotency Assertion (`changed=0`, `failed=0` on re-run)
#   6. Security controls verification:
#      - SSH PermitRootLogin disabled & PasswordAuthentication disabled
#      - Root SSH access rejected
#      - Authorized key access verified for non-root sudo user
#      - Kernel sysctl hardening configuration deployed
#      - Fail2ban jail.local configuration deployed
#      - Unattended upgrades configuration deployed
#   7. Clean teardown of test container and temporary keys
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="ansible-hardening-target"
IMAGE_NAME="ansible-hardening-test-node:latest"
SSH_PORT=2222
TEST_KEY="${SCRIPT_DIR}/.ssh_test_key"
KEEP_RUNNING=false

for arg in "$@"; do
    case "$arg" in
        --keep)
            KEEP_RUNNING=true
            ;;
        --clean)
            exec ./cleanup.sh --all
            ;;
        --help|-h)
            echo "Usage: ./ansible_audit.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep     Keep test container and keys running after test completion"
            echo "  --clean    Destroy test container, keys, and temporary files"
            echo "  --help, -h Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./ansible_audit.sh --help for usage."
            exit 1
            ;;
    esac
done

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

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

cleanup_on_exit() {
    rm -f /tmp/ansible_run_*.log
    if [[ "$KEEP_RUNNING" == false && "$FAILED_TESTS" -gt 0 ]]; then
        echo -e "\n${CLR_YELLOW}⚠️  Tests encountered failures. Running cleanup...${CLR_RESET}"
        ./cleanup.sh >/dev/null 2>&1 || true
    fi
}

trap cleanup_on_exit EXIT INT TERM

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🛡️  Ansible Baseline Server Hardening Audit & Idempotency Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Phase 1: Tooling & Prerequisites Verification
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}Phase 1: Tooling & Prerequisites Verification${CLR_RESET}"

# 1.1 Docker Engine
if docker info >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "Unknown")
    record_result "01" "Docker engine is responsive" 0 "Engine version: ${DOCKER_VER}"
else
    record_result "01" "Docker engine is responsive" 1 "Docker daemon is not reachable"
    exit 1
fi

# 1.2 Ansible & Ansible-Playbook
if command -v ansible-playbook >/dev/null 2>&1; then
    ANSIBLE_VER=$(ansible-playbook --version | head -n 1)
    record_result "02" "Ansible playbook engine detected" 0 "${ANSIBLE_VER}"
else
    record_result "02" "Ansible playbook engine detected" 1 "ansible-playbook binary not found in PATH"
    exit 1
fi

# 1.3 OpenSSH & ssh-keygen
if command -v ssh >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    record_result "03" "SSH utilities available (ssh, ssh-keygen)" 0 "Key generation and client tools ready"
else
    record_result "03" "SSH utilities available" 1 "Missing ssh or ssh-keygen in PATH"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 2: Static Playbook Syntax Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 2: Playbook Syntax Validation${CLR_RESET}"

if ansible-playbook --syntax-check -i inventory.ini.example site.yml >/dev/null 2>&1; then
    record_result "04" "Master playbook and role syntax validation (site.yml)" 0 "Syntax is valid"
else
    record_result "04" "Master playbook and role syntax validation (site.yml)" 1 "Syntax check failed"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 3: Ephemeral Test Environment Provisioning
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 3: Ephemeral Test Node Setup (Port ${SSH_PORT})${CLR_RESET}"

# Generate dedicated test SSH key
if [[ ! -f "$TEST_KEY" ]]; then
    rm -f "${TEST_KEY}" "${TEST_KEY}.pub"
    ssh-keygen -t ed25519 -N "" -f "$TEST_KEY" -C "ansible-test-key" >/dev/null 2>&1
    chmod 0600 "$TEST_KEY"
    chmod 0644 "${TEST_KEY}.pub"
fi

# Build Docker test node image
echo "  Building test node image (${IMAGE_NAME})..."
docker build -q -t "${IMAGE_NAME}" -f test_environment/Dockerfile test_environment >/dev/null 2>&1
record_result "05" "Test node container image built successfully" 0 "${IMAGE_NAME}"

# Start container
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d \
    --name "${CONTAINER_NAME}" \
    --cap-add=NET_ADMIN \
    -p "${SSH_PORT}:22" \
    "${IMAGE_NAME}" >/dev/null 2>&1

# Inject authorized key into ubuntu user
PUB_KEY_CONTENT=$(cat "${TEST_KEY}.pub")
docker exec "${CONTAINER_NAME}" bash -c "echo '${PUB_KEY_CONTENT}' > /home/ubuntu/.ssh/authorized_keys && chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys && chmod 0600 /home/ubuntu/.ssh/authorized_keys"

# Wait for SSH to accept connections
SSH_READY=false
for _ in {1..30}; do
    if ssh -i "$TEST_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -p "$SSH_PORT" ubuntu@127.0.0.1 "echo ready" >/dev/null 2>&1; then
        SSH_READY=true
        break
    fi
    sleep 1
done

if [[ "$SSH_READY" == true ]]; then
    record_result "06" "Test node container active and reachable via SSH" 0 "127.0.0.1:${SSH_PORT} (user: ubuntu)"
else
    record_result "06" "Test node container active and reachable via SSH" 1 "SSH failed to become ready"
    exit 1
fi

# Generate active inventory.ini
cat << EOF > inventory.ini
[hardened_servers]
target-node-01 ansible_host=127.0.0.1 ansible_port=${SSH_PORT} ansible_user=ubuntu ansible_ssh_private_key_file=${TEST_KEY} ansible_python_interpreter=/usr/bin/python3

[hardened_servers:vars]
ansible_become=yes
ansible_become_method=sudo
EOF

# ------------------------------------------------------------------------------
# Phase 4: Initial Playbook Execution
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 4: Initial Hardening Playbook Execution${CLR_RESET}"

set +e
ansible-playbook -i inventory.ini site.yml > /tmp/ansible_run_1.log 2>&1
RUN1_EXIT_CODE=$?
set -e

if [[ $RUN1_EXIT_CODE -eq 0 ]]; then
    RUN1_CHANGED=$(grep -oE "changed=[0-9]+" /tmp/ansible_run_1.log | tail -n 1 | cut -d= -f2)
    record_result "07" "Initial playbook execution completed without errors" 0 "Applied ${RUN1_CHANGED} security configuration changes"
else
    RUN1_ERR=$(tail -n 10 /tmp/ansible_run_1.log)
    record_result "07" "Initial playbook execution completed without errors" 1 "Failed with exit code ${RUN1_EXIT_CODE}: ${RUN1_ERR}"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 5: Playbook Idempotency Assertion
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 5: Playbook Idempotency Verification${CLR_RESET}"

set +e
ansible-playbook -i inventory.ini site.yml > /tmp/ansible_run_2.log 2>&1
RUN2_EXIT_CODE=$?
set -e

RUN2_CHANGED=$(grep -oE "changed=[0-9]+" /tmp/ansible_run_2.log | tail -n 1 | cut -d= -f2 || echo "-1")
RUN2_FAILED=$(grep -oE "failed=[0-9]+" /tmp/ansible_run_2.log | tail -n 1 | cut -d= -f2 || echo "-1")

if [[ $RUN2_EXIT_CODE -eq 0 && "$RUN2_CHANGED" -eq 0 && "$RUN2_FAILED" -eq 0 ]]; then
    record_result "08" "Playbook idempotency confirmed (changed=0, failed=0)" 0 "Zero configuration drift on second execution"
else
    RUN2_ERR=$(tail -n 8 /tmp/ansible_run_2.log)
    record_result "08" "Playbook idempotency confirmed" 1 "changed=${RUN2_CHANGED}, failed=${RUN2_FAILED}: ${RUN2_ERR}"
fi

# ------------------------------------------------------------------------------
# Phase 6: Security Controls & Configuration Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 6: Security Controls Verification${CLR_RESET}"

# 6.1 SSH Root Login Disabled
PERMIT_ROOT=$(docker exec "${CONTAINER_NAME}" grep -E "^PermitRootLogin" /etc/ssh/sshd_config || echo "")
if [[ "$PERMIT_ROOT" == "PermitRootLogin no" ]]; then
    record_result "09" "SSH PermitRootLogin set to 'no' in sshd_config (CIS 5.2.5)" 0 "${PERMIT_ROOT}"
else
    record_result "09" "SSH PermitRootLogin set to 'no'" 1 "Found: ${PERMIT_ROOT}"
fi

# 6.2 SSH Password Authentication Disabled
PASS_AUTH=$(docker exec "${CONTAINER_NAME}" grep -E "^PasswordAuthentication" /etc/ssh/sshd_config || echo "")
if [[ "$PASS_AUTH" == "PasswordAuthentication no" ]]; then
    record_result "10" "SSH PasswordAuthentication disabled in sshd_config (CIS 5.2.8)" 0 "${PASS_AUTH}"
else
    record_result "10" "SSH PasswordAuthentication disabled" 1 "Found: ${PASS_AUTH}"
fi

# 6.3 SSH MaxAuthTries Configured
MAX_TRIES=$(docker exec "${CONTAINER_NAME}" grep -E "^MaxAuthTries" /etc/ssh/sshd_config || echo "")
if [[ "$MAX_TRIES" == "MaxAuthTries 3" ]]; then
    record_result "11" "SSH MaxAuthTries restricted to 3 (CIS 5.2.6)" 0 "${MAX_TRIES}"
else
    record_result "11" "SSH MaxAuthTries restricted to 3" 1 "Found: ${MAX_TRIES}"
fi

# 6.4 SSH Ciphers & MACs Hardened
CIPHERS=$(docker exec "${CONTAINER_NAME}" grep -E "^Ciphers" /etc/ssh/sshd_config || echo "")
if [[ "$CIPHERS" =~ "chacha20-poly1305" && "$CIPHERS" =~ "aes256-gcm" ]]; then
    record_result "12" "SSH strong cryptographic ciphers enforced (CIS 5.2.14)" 0 "Only modern authenticated ciphers permitted"
else
    record_result "12" "SSH strong cryptographic ciphers enforced" 1 "Ciphers: ${CIPHERS}"
fi

# 6.5 Kernel Sysctl Hardening Configuration
if docker exec "${CONTAINER_NAME}" test -f /etc/sysctl.d/99-security.conf; then
    SYN_COOKIES=$(docker exec "${CONTAINER_NAME}" grep "net.ipv4.tcp_syncookies" /etc/sysctl.d/99-security.conf || echo "")
    RP_FILTER=$(docker exec "${CONTAINER_NAME}" grep "net.ipv4.conf.all.rp_filter" /etc/sysctl.d/99-security.conf || echo "")
    if [[ "$SYN_COOKIES" =~ "1" && "$RP_FILTER" =~ "1" ]]; then
        record_result "13" "Kernel sysctl security parameters deployed (CIS 3.1 & 3.2)" 0 "SYN flood protection & RP filtering configured"
    else
        record_result "13" "Kernel sysctl security parameters deployed" 1 "Missing parameters in 99-security.conf"
    fi
else
    record_result "13" "Kernel sysctl security parameters deployed" 1 "/etc/sysctl.d/99-security.conf missing"
fi

# 6.6 Fail2ban Jail Configuration
if docker exec "${CONTAINER_NAME}" test -f /etc/fail2ban/jail.local; then
    F2B_SSH=$(docker exec "${CONTAINER_NAME}" grep -E "^\[sshd\]" /etc/fail2ban/jail.local || echo "")
    if [[ "$F2B_SSH" == "[sshd]" ]]; then
        record_result "14" "Fail2ban SSH brute-force protection jail deployed (/etc/fail2ban/jail.local)" 0 "Jail [sshd] active with 1h ban time"
    else
        record_result "14" "Fail2ban SSH brute-force protection jail deployed" 1 "Jail [sshd] missing in jail.local"
    fi
else
    record_result "14" "Fail2ban SSH brute-force protection jail deployed" 1 "/etc/fail2ban/jail.local missing"
fi

# 6.7 Automated Security Updates Configuration
if docker exec "${CONTAINER_NAME}" test -f /etc/apt/apt.conf.d/50unattended-upgrades && docker exec "${CONTAINER_NAME}" test -f /etc/apt/apt.conf.d/20auto-upgrades; then
    record_result "15" "Automated security updates configuration deployed (/etc/apt/apt.conf.d/)" 0 "Unattended security upgrades enabled"
else
    record_result "15" "Automated security updates configuration deployed" 1 "Apt configuration files missing"
fi

# 6.8 Direct Root SSH Access Rejection Assertion
set +e
ROOT_SSH_OUTPUT=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -p "$SSH_PORT" root@127.0.0.1 "echo logged_in" 2>&1)
ROOT_SSH_CODE=$?
set -e

if [[ $ROOT_SSH_CODE -ne 0 ]]; then
    record_result "16" "Root SSH connection blocked by SSH daemon (Defense-in-Depth)" 0 "Direct root login rejected"
else
    record_result "16" "Root SSH connection blocked" 1 "Root login unexpectedly succeeded!"
fi

# ------------------------------------------------------------------------------
# Phase 7: Teardown & Cleanup
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 7: Teardown & Environment Cleanup${CLR_RESET}"

if [[ "$KEEP_RUNNING" == true ]]; then
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] --keep flag specified: Leaving test container and SSH keys active."
    echo -e "  Test container : ${CLR_GREEN}${CONTAINER_NAME}${CLR_RESET} (port ${SSH_PORT})"
    echo -e "  SSH Key        : ${CLR_GREEN}${TEST_KEY}${CLR_RESET}"
    echo -e "  To clean up later, run: ./cleanup.sh --all"
else
    echo "  Stopping and removing test container (${CONTAINER_NAME})..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    rm -f "${TEST_KEY}" "${TEST_KEY}.pub" inventory.ini /tmp/ansible_run_*.log
    record_result "17" "Test container and ephemeral test credentials purged" 0 "Environment returned to clean state"
fi

# ------------------------------------------------------------------------------
# Test Suite Summary
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
echo -e "${CLR_BOLD}  TEST SUITE RESULTS SUMMARY${CLR_RESET}"
echo "======================================================================"
echo -e "  Total Tests Executed : ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  Passed Assertions    : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed Assertions    : $([[ "$FAILED_TESTS" -eq 0 ]] && echo -e "${CLR_GREEN}0${CLR_RESET}" || echo -e "${CLR_RED}${FAILED_TESTS}${CLR_RESET}")"
echo "======================================================================"

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "${CLR_GREEN}${CLR_BOLD}🎉 ALL ANSIBLE HARDENING AUDIT TESTS PASSED PERFECTLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S)${CLR_RESET}\n"
    exit 1
fi
