#!/usr/bin/env bash
# ==============================================================================
# oom_monitor.sh - Docker Real-Time OOM Monitor & Diagnostic Profiler
# ==============================================================================
# Captures Docker daemon event streams (oom, kill, die) and provides deep
# post-mortem diagnostics on exit codes (exit code 137) and cgroups v2 metrics.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_MAGENTA="\033[1;35m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

show_help() {
    cat <<EOF
Usage: ./oom_monitor.sh [COMMAND] [OPTIONS]

Docker Out-Of-Memory (OOM) real-time event monitor and diagnostic analyzer.

Commands:
  --stream, --watch        Listen for live Docker daemon events (oom, die, kill)
  --inspect <CONTAINER>    Run in-depth post-mortem diagnostic on a container
  --summary                Scan and list all stopped/running containers with OOM status
  -h, --help               Display this help menu

Examples:
  ./oom_monitor.sh --stream
  ./oom_monitor.sh --inspect devops-oom-victim
  ./oom_monitor.sh --summary
EOF
}

print_header() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🔍 Docker OOM Profiler & Kernel Event Diagnostic Utility"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

stream_events() {
    print_header
    echo -e "${CLR_YELLOW}📡 Listening for Docker daemon events (Press Ctrl+C to stop)...${CLR_RESET}"
    echo -e "${CLR_GRAY}Filtered events: oom, die, kill, restart${CLR_RESET}"
    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"

    # Listen to docker socket events
    docker events \
        --filter "type=container" \
        --filter "event=oom" \
        --filter "event=die" \
        --filter "event=kill" \
        --filter "event=restart" \
        --format "{{json .}}" | while read -r event_json; do
            local action actor_name actor_img exit_code timestamp
            action=$(echo "$event_json" | grep -o '"Action":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
            actor_name=$(echo "$event_json" | grep -o '"name":"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "unknown")
            actor_img=$(echo "$event_json" | grep -o '"image":"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "unknown")
            exit_code=$(echo "$event_json" | grep -o '"exitCode":"[^"]*"' | cut -d'"' -f4 || echo "N/A")
            timestamp=$(date +"%Y-%m-%d %H:%M:%S")

            if [[ "$action" == "oom" ]]; then
                echo -e "${timestamp} [${CLR_RED}${CLR_BOLD}🚨 OOM EVENT${CLR_RESET}] Container: ${CLR_BOLD}${actor_name}${CLR_RESET} (${actor_img})"
                echo -e "           ↳ ${CLR_RED}Kernel Out-Of-Memory Killer triggered for this cgroup!${CLR_RESET}"
            elif [[ "$action" == "die" ]]; then
                if [[ "$exit_code" == "137" ]]; then
                    echo -e "${timestamp} [${CLR_RED}💀 DIE EVENT${CLR_RESET}] Container: ${CLR_BOLD}${actor_name}${CLR_RESET} ExitCode: ${CLR_RED}${exit_code} (SIGKILL / OOM)${CLR_RESET}"
                elif [[ "$exit_code" == "0" ]]; then
                    echo -e "${timestamp} [${CLR_GREEN}✔ DIE EVENT${CLR_RESET}] Container: ${CLR_BOLD}${actor_name}${CLR_RESET} ExitCode: ${CLR_GREEN}0 (Clean Exit)${CLR_RESET}"
                else
                    echo -e "${timestamp} [${CLR_YELLOW}⚡ DIE EVENT${CLR_RESET}] Container: ${CLR_BOLD}${actor_name}${CLR_RESET} ExitCode: ${CLR_YELLOW}${exit_code}${CLR_RESET}"
                fi
            elif [[ "$action" == "kill" ]]; then
                echo -e "${timestamp} [${CLR_MAGENTA}🗡️  KILL EVENT${CLR_RESET}] Container: ${CLR_BOLD}${actor_name}${CLR_RESET}"
            else
                echo -e "${timestamp} [ℹ️  ${action^^}] Container: ${actor_name}"
            fi
        done
}

inspect_container() {
    local target="$1"
    print_header

    if ! docker inspect "$target" >/dev/null 2>&1; then
        echo -e "${CLR_RED}Error: Container '${target}' not found.${CLR_RESET}" >&2
        exit 1
    fi

    local inspect_json
    inspect_json=$(docker inspect "$target")

    local status exit_code oom_killed error_msg mem_limit_bytes mem_swap_bytes nanocpus
    status=$(echo "$inspect_json" | grep -o '"Status": "[^"]*"' | head -n1 | cut -d'"' -f4)
    exit_code=$(echo "$inspect_json" | grep -o '"ExitCode": [0-9]*' | head -n1 | cut -d' ' -f2)
    oom_killed=$(echo "$inspect_json" | grep -o '"OOMKilled": [a-z]*' | head -n1 | cut -d' ' -f2)
    error_msg=$(echo "$inspect_json" | grep -o '"Error": "[^"]*"' | head -n1 | cut -d'"' -f4)
    mem_limit_bytes=$(echo "$inspect_json" | grep -o '"Memory": [0-9]*' | head -n1 | cut -d' ' -f2)
    mem_swap_bytes=$(echo "$inspect_json" | grep -o '"MemorySwap": [0-9]*' | head -n1 | cut -d' ' -f2)
    nanocpus=$(echo "$inspect_json" | grep -o '"NanoCpus": [0-9]*' | head -n1 | cut -d' ' -f2)

    local mem_limit_mb="unlimited"
    if [[ -n "$mem_limit_bytes" && "$mem_limit_bytes" -gt 0 ]]; then
        mem_limit_mb="$(( mem_limit_bytes / 1024 / 1024 )) MB"
    fi

    local cpu_limit="unlimited"
    if [[ -n "$nanocpus" && "$nanocpus" -gt 0 ]]; then
        cpu_limit=$(awk "BEGIN {printf \"%.2f CPUs\", $nanocpus / 1000000000}")
    fi

    echo -e "${CLR_BOLD}📦 Container Inspection: ${CLR_CYAN}${target}${CLR_RESET}"
    echo -e "  • State Status:        ${status}"
    echo -e "  • Configured Memory:   ${mem_limit_mb}"
    echo -e "  • Configured CPU:      ${cpu_limit}"
    
    if [[ "$oom_killed" == "true" ]]; then
        echo -e "  • OOMKilled Flag:      ${CLR_RED}${CLR_BOLD}true (KILLED BY LINUX KERNEL OOM)${CLR_RESET}"
    else
        echo -e "  • OOMKilled Flag:      ${CLR_GREEN}false${CLR_RESET}"
    fi

    if [[ "$exit_code" == "137" ]]; then
        echo -e "  • Process Exit Code:   ${CLR_RED}${CLR_BOLD}137${CLR_RESET}"
        echo -e ""
        echo -e "${CLR_YELLOW}${CLR_BOLD}🧠 Exit Code 137 Breakdown:${CLR_RESET}"
        echo -e "    Standard Unix Exit Formula: 128 + Signal Number"
        echo -e "    Exit Code 137 = 128 + 9 (SIGKILL)"
        echo -e "    When a container exceeds its cgroup memory limit, the Linux Kernel"
        echo -e "    OOM-Killer sends an uncatchable ${CLR_RED}SIGKILL (signal 9)${CLR_RESET} to immediately"
        echo -e "    reclaim memory and prevent host kernel starvation."
    elif [[ "$exit_code" == "0" ]]; then
        echo -e "  • Process Exit Code:   ${CLR_GREEN}0 (Clean Success)${CLR_RESET}"
    else
        echo -e "  • Process Exit Code:   ${CLR_YELLOW}${exit_code}${CLR_RESET}"
    fi

    if [[ -n "$error_msg" ]]; then
        echo -e "  • Error Details:       ${CLR_RED}${error_msg}${CLR_RESET}"
    fi

    echo -e "${CLR_GRAY}----------------------------------------------------------------------${CLR_RESET}"
}

summary_containers() {
    print_header
    echo -e "${CLR_BOLD}📋 Active and Stopped Containers Resource Audit:${CLR_RESET}"
    echo ""
    printf "%-25s %-12s %-12s %-14s %-14s\n" "CONTAINER NAME" "STATUS" "EXIT CODE" "OOM KILLED?" "MEMORY LIMIT"
    echo "-------------------------------------------------------------------------------"

    local containers
    containers=$(docker ps -a --format "{{.Names}}")

    if [[ -z "$containers" ]]; then
        echo "No containers found."
        return
    fi

    for c in $containers; do
        local status exit_code oom_killed mem_bytes mem_str
        status=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
        exit_code=$(docker inspect "$c" --format '{{.State.ExitCode}}' 2>/dev/null || echo "-")
        oom_killed=$(docker inspect "$c" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "false")
        mem_bytes=$(docker inspect "$c" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")

        if [[ "$mem_bytes" -gt 0 ]]; then
            mem_str="$(( mem_bytes / 1024 / 1024 )) MB"
        else
            mem_str="unlimited"
        fi

        local oom_display
        if [[ "$oom_killed" == "true" ]]; then
            oom_display="${CLR_RED}TRUE (OOM)${CLR_RESET}"
        else
            oom_display="${CLR_GREEN}false${CLR_RESET}"
        fi

        local code_display
        if [[ "$exit_code" == "137" ]]; then
            code_display="${CLR_RED}137${CLR_RESET}"
        elif [[ "$exit_code" == "0" ]]; then
            code_display="${CLR_GREEN}0${CLR_RESET}"
        else
            code_display="${CLR_YELLOW}${exit_code}${CLR_RESET}"
        fi

        printf "%-25s %-12s %-20b %-22b %-14s\n" "$c" "$status" "$code_display" "$oom_display" "$mem_str"
    done
    echo "-------------------------------------------------------------------------------"
}

# Entrypoint argument parsing
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

case "$1" in
    --stream|--watch)
        stream_events
        ;;
    --inspect)
        if [[ $# -lt 2 ]]; then
            echo -e "${CLR_RED}Error: --inspect requires a container name or ID.${CLR_RESET}" >&2
            exit 1
        fi
        inspect_container "$2"
        ;;
    --summary)
        summary_containers
        ;;
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        echo -e "${CLR_RED}Error: Unknown command '$1'${CLR_RESET}" >&2
        show_help
        exit 1
        ;;
esac
