#!/usr/bin/env bash
# ==============================================================================
# Linux Security Event & Attack Vector Simulator
# Simulates unauthorized /etc modifications, privilege escalation, and execve
# ==============================================================================
set -e

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

CONTAINER_NAME="audit-siem-shipper"

echo -e "\n${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  💥 Linux Security Event & Intrusion Vector Simulator${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}======================================================================${CLR_RESET}\n"

# Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "  [${CLR_RED}ERROR${CLR_RESET}] Container '${CONTAINER_NAME}' is not running. Start it with docker compose up -d."
    exit 1
fi
echo -e "  [${CLR_GREEN}CONNECTED${CLR_RESET}] Shipper container '${CONTAINER_NAME}' is active."

# Python helper to inject authentic Linux Kernel audit lines into /var/log/audit/audit.log
inject_audit_event() {
    local key="$1"
    local syscall_num="$2"
    local file_path="$3"
    local command_line="$4"
    local auid="$5"
    local uid="$6"
    local euid="$7"
    local comm="$8"
    local exe="$9"

    docker exec -i "$CONTAINER_NAME" python3 -c "
import binascii, sys, time

key = sys.argv[1]
syscall_num = sys.argv[2]
file_path = sys.argv[3]
command_line = sys.argv[4]
auid = sys.argv[5]
uid = sys.argv[6]
euid = sys.argv[7]
comm = sys.argv[8]
exe = sys.argv[9]

now = time.time()
serial = int(now * 1000) % 999999
event_id = f'{now:.3f}:{serial}'

hex_proctitle = binascii.hexlify(command_line.encode('utf-8')).decode('ascii')

lines = []
lines.append(
    f'type=SYSCALL msg=audit({event_id}): arch=c000003e syscall={syscall_num} success=yes exit=0 '
    f'a0=ffffff9c a1=7ffd3a a2=241 a3=1b6 items=1 ppid=1020 pid=2450 auid={auid} uid={uid} '
    f'gid=0 euid={euid} suid=0 fsuid=0 tty=pts1 ses=2 comm=\"{comm}\" exe=\"{exe}\" key=\"{key}\"'
)

if file_path != 'NONE':
    lines.append(
        f'type=PATH msg=audit({event_id}): item=0 name=\"{file_path}\" inode=41920 dev=fd:00 '
        f'mode=0100644 ouid=0 ogid=0 rdev=00:00 nametype=NORMAL cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0'
    )

lines.append(f'type=PROCTITLE msg=audit({event_id}): proctitle={hex_proctitle}')

if key in ('user_commands', 'priv_escalation_syscalls'):
    parts = command_line.split()
    exec_args = ' '.join(f'a{i}=\"{p}\"' for i, p in enumerate(parts))
    lines.append(f'type=EXECVE msg=audit({event_id}): argc={len(parts)} {exec_args}')

with open('/var/log/audit/audit.log', 'a', encoding='utf-8') as f:
    for l in lines:
        f.write(l + '\n')
" "$key" "$syscall_num" "$file_path" "$command_line" "$auid" "$uid" "$euid" "$comm" "$exe"
}

# ------------------------------------------------------------------------------
# Attack Vector 1: Unauthorized modification of /etc/passwd (Backdoor User Creation)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_RED}${CLR_BOLD}▶ [Attack Vector 1/5] Injecting /etc/passwd Tampering (FIM - Critical)...${CLR_RESET}"
echo -e "  Adversary action: echo 'backdoor_root:x:0:0::/root:/bin/bash' >> /etc/passwd"
inject_audit_event "identity_changes" "257" "/etc/passwd" "echo backdoor_root:x:0:0::/root:/bin/bash >> /etc/passwd" "1000" "0" "0" "sh" "/bin/bash"
echo -e "  [${CLR_GREEN}LOGGED${CLR_RESET}] Emitted audit event with key='identity_changes' (MITRE T1078)."
sleep 0.5

# ------------------------------------------------------------------------------
# Attack Vector 2: Tampering with /etc/sudoers (Privilege Escalation Grant)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_RED}${CLR_BOLD}▶ [Attack Vector 2/5] Injecting /etc/sudoers Tampering (Privilege Escalation - Critical)...${CLR_RESET}"
echo -e "  Adversary action: echo 'attacker ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers"
inject_audit_event "privilege_escalation" "257" "/etc/sudoers" "echo attacker ALL=(ALL) NOPASSWD: ALL >> /etc/sudoers" "1000" "0" "0" "visudo" "/usr/sbin/visudo"
echo -e "  [${CLR_GREEN}LOGGED${CLR_RESET}] Emitted audit event with key='privilege_escalation' (MITRE T1548.003)."
sleep 0.5

# ------------------------------------------------------------------------------
# Attack Vector 3: Privilege Escalation Syscall (setuid to root)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_RED}${CLR_BOLD}▶ [Attack Vector 3/5] Injecting setuid(0) Privilege Escalation Syscall (High)...${CLR_RESET}"
echo -e "  Adversary action: /tmp/exploit_payload invoking setuid(0)"
inject_audit_event "priv_escalation_syscalls" "105" "NONE" "/tmp/exploit_payload" "1001" "1001" "0" "exploit" "/tmp/exploit_payload"
echo -e "  [${CLR_GREEN}LOGGED${CLR_RESET}] Emitted audit event with key='priv_escalation_syscalls' (MITRE T1068)."
sleep 0.5

# ------------------------------------------------------------------------------
# Attack Vector 4: Suspicious Process Execution (Reverse Shell & Shadow Exfiltration)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_RED}${CLR_BOLD}▶ [Attack Vector 4/5] Injecting Suspicious Process Execution (execve - Medium/High)...${CLR_RESET}"
echo -e "  Adversary action: /bin/nc -lvnp 4444 -e /bin/bash"
inject_audit_event "user_commands" "59" "NONE" "/bin/nc -lvnp 4444 -e /bin/bash" "1000" "1000" "1000" "nc" "/bin/nc"
echo -e "  Adversary action: cat /etc/shadow"
inject_audit_event "identity_changes" "257" "/etc/shadow" "cat /etc/shadow" "1000" "0" "0" "cat" "/bin/cat"
echo -e "  [${CLR_GREEN}LOGGED${CLR_RESET}] Emitted audit events for reverse shell and shadow file reading."
sleep 0.5

# ------------------------------------------------------------------------------
# Attack Vector 5: SSH Daemon Configuration Tampering (Persistence)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_RED}${CLR_BOLD}▶ [Attack Vector 5/5] Injecting SSH Daemon Configuration Tampering (High)...${CLR_RESET}"
echo -e "  Adversary action: echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
inject_audit_event "sshd_tamper" "257" "/etc/ssh/sshd_config" "sed -i s/PermitRootLogin_no/PermitRootLogin_yes/ /etc/ssh/sshd_config" "1000" "0" "0" "sed" "/usr/bin/sed"
echo -e "  [${CLR_GREEN}LOGGED${CLR_RESET}] Emitted audit event with key='sshd_tamper' (MITRE T1098.004)."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ All 5 security attack scenarios simulated successfully!${CLR_RESET}"
echo -e "  Check SIEM Security Feed: ${CLR_CYAN}http://localhost:9099${CLR_RESET}\n"
