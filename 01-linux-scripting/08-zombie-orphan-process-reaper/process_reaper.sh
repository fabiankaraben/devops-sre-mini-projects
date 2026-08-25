#!/usr/bin/env bash
# ==============================================================================
# Script Name: process_reaper.sh
# Description: Pure POSIX / Bash Zombie and Orphan Process Inspector & Reaper.
#              Parses ps and /proc to identify defunct processes and remediate them.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -uo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
BOLD_RED="\033[1;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"
BOLD="\033[1m"
DIM="\033[2m"
NC="\033[0m"

ACTION="scan"
JSON_OUTPUT=0
NO_FAIL=0

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Zombie and Orphan Process Reaper (POSIX/Bash Edition)

Options:
  --scan               Scan and display zombie & orphan process diagnostics (default)
  --reap-sigchld       Send SIGCHLD (signal 17) to parents of zombie processes
  --kill-parents       Terminate negligent parent processes to force PID 1 re-parenting
  -j, --json           Output summary in JSON format
  --no-fail            Always return exit code 0 regardless of zombie count
  -h, --help           Display this help message and exit

Examples:
  $(basename "$0") --scan
  $(basename "$0") --kill-parents
  $(basename "$0") --json
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scan)
            ACTION="scan"
            shift
            ;;
        --reap-sigchld)
            ACTION="reap-sigchld"
            shift
            ;;
        --kill-parents)
            ACTION="kill-parents"
            shift
            ;;
        -j|--json)
            JSON_OUTPUT=1
            shift
            ;;
        --no-fail)
            NO_FAIL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            usage
            exit 3
            ;;
    esac
done

# Extract process list using ps
# Format: PID PPID STATE COMMAND
RAW_PS=$(ps -axo pid,ppid,state,comm 2>/dev/null || ps -eo pid,ppid,state,comm 2>/dev/null)

ZOMBIE_PIDS=()
ZOMBIE_PPIDS=()
ZOMBIE_NAMES=()

while read -r line; do
    pid=$(echo "$line" | awk '{print $1}')
    ppid=$(echo "$line" | awk '{print $2}')
    state=$(echo "$line" | awk '{print $3}')
    comm=$(echo "$line" | awk '{$1=$2=$3=""; print $0}' | sed 's/^[[:space:]]*//')

    if [[ "$state" =~ ^[Zz] ]] || [[ "$comm" =~ defunct ]]; then
        ZOMBIE_PIDS+=("$pid")
        ZOMBIE_PPIDS+=("$ppid")
        ZOMBIE_NAMES+=("$comm")
    fi
done < <(echo "$RAW_PS" | tail -n +2)

TOTAL_ZOMBIES=${#ZOMBIE_PIDS[@]}

# Deduplicate parent PIDs
NEGLIGENT_PARENTS=()
if [[ $TOTAL_ZOMBIES -gt 0 ]]; then
    for ppid in "${ZOMBIE_PPIDS[@]}"; do
        if [[ ! " ${NEGLIGENT_PARENTS[*]:-} " =~ " ${ppid} " ]]; then
            NEGLIGENT_PARENTS+=("$ppid")
        fi
    done
fi

TOTAL_PARENTS=${#NEGLIGENT_PARENTS[@]}

# Remediation Actions
ACTIONS_TAKEN=()

if [[ "$ACTION" == "reap-sigchld" && $TOTAL_PARENTS -gt 0 ]]; then
    for ppid in "${NEGLIGENT_PARENTS[@]}"; do
        if kill -17 "$ppid" 2>/dev/null; then
            ACTIONS_TAKEN+=("Sent SIGCHLD to parent PID $ppid")
        fi
    done
elif [[ "$ACTION" == "kill-parents" && $TOTAL_PARENTS -gt 0 ]]; then
    for ppid in "${NEGLIGENT_PARENTS[@]}"; do
        if [[ $ppid -gt 1 ]]; then
            if kill -9 "$ppid" 2>/dev/null; then
                ACTIONS_TAKEN+=("Killed parent PID $ppid with SIGKILL (re-parenting to PID 1)")
            fi
        fi
    done
fi

# Output Rendering
if [[ $JSON_OUTPUT -eq 0 ]]; then
    echo -e "\n${BOLD}${BLUE}========================================================================================================${NC}"
    echo -e "${BOLD}                     ZOMBIE PROCESS REAPER (POSIX/BASH EDITION)                                         ${NC}"
    echo -e "${BOLD}${BLUE}========================================================================================================${NC}\n"

    echo -e "${BOLD}ZOMBIE (DEFUNCT) PROCESSES (${TOTAL_ZOMBIES} found):${NC}"
    if [[ $TOTAL_ZOMBIES -gt 0 ]]; then
        printf "  ${BOLD}%-8s  %-8s  %-30s${NC}\n" "PID" "PPID" "COMMAND"
        echo -e "${DIM}  --------------------------------------------------------------------------------------${NC}"
        for ((i=0; i<TOTAL_ZOMBIES; i++)); do
            printf "  ${BOLD_RED}%-8s${NC}  %-8s  %-30s\n" "${ZOMBIE_PIDS[i]}" "${ZOMBIE_PPIDS[i]}" "${ZOMBIE_NAMES[i]}"
        done
    else
        echo -e "  ${GREEN}✔ No zombie processes detected. Process table is clean.${NC}"
    fi

    echo -e "\n${BOLD}NEGLIGENT PARENT PROCESSES (${TOTAL_PARENTS} found):${NC}"
    if [[ $TOTAL_PARENTS -gt 0 ]]; then
        for ppid in "${NEGLIGENT_PARENTS[@]}"; do
            echo -e "  - ${YELLOW}PPID $ppid${NC} (Remediation: 'kill -9 $ppid')"
        done
    else
        echo -e "  ${GREEN}✔ No negligent parents found.${NC}"
    fi

    if [[ ${#ACTIONS_TAKEN[@]} -gt 0 ]]; then
        echo -e "\n${BOLD}REMEDIATION ACTIONS EXECUTED:${NC}"
        for act in "${ACTIONS_TAKEN[@]}"; do
            echo -e "  - [${GREEN}SUCCESS${NC}] $act"
        done
    fi

    echo -e "\n${DIM}========================================================================================================${NC}\n"
else
    cat << EOF
{
  "summary": {
    "zombie_count": $TOTAL_ZOMBIES,
    "negligent_parent_count": $TOTAL_PARENTS,
    "action_executed": "$ACTION",
    "actions_count": ${#ACTIONS_TAKEN[@]}
  }
}
EOF
fi

if [[ $NO_FAIL -eq 1 ]]; then
    exit 0
fi

if [[ $TOTAL_ZOMBIES -gt 0 && "$ACTION" == "scan" ]]; then
    exit 1
fi

exit 0
