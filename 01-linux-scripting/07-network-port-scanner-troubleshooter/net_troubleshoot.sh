#!/usr/bin/env bash
# ==============================================================================
# Script Name: net_troubleshoot.sh
# Description: Pure POSIX / Bash Network Port Scanner and Troubleshooter.
#              Performs TCP connect scans using /dev/tcp or netcat (nc).
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -uo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
BOLD="\033[1m"
DIM="\033[2m"
NC="\033[0m"

TIMEOUT=1
JSON_OUTPUT=0
MARKDOWN_OUTPUT=0
NO_FAIL=0
TARGETS=()
PORTS=()

get_service_name() {
    local port="$1"
    case "$port" in
        21) echo "FTP" ;;
        22) echo "SSH" ;;
        25) echo "SMTP" ;;
        53) echo "DNS" ;;
        80) echo "HTTP" ;;
        443) echo "HTTPS" ;;
        3306) echo "MySQL" ;;
        5432) echo "PostgreSQL" ;;
        6379) echo "Redis" ;;
        8080) echo "HTTP-Proxy" ;;
        8443) echo "HTTPS-Alt" ;;
        9022) echo "SSH-Mock" ;;
        9080) echo "HTTP-Mock" ;;
        9081) echo "API-Mock" ;;
        9379) echo "Redis-Mock" ;;
        9432) echo "Postgres-Mock" ;;
        9843) echo "HTTPS-Mock" ;;
        9999) echo "Filtered-Mock" ;;
        *) echo "Unknown" ;;
    esac
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Network Port Scanner and Troubleshooter (POSIX/Bash Edition)

Options:
  -t, --target <host/IP>       Target host or IP address (e.g. 127.0.0.1, localhost).
                               Can be specified multiple times.
  -f, --file <path>            File containing list of targets (one per line).
  -p, --ports <ports>          Port specification (e.g. '80,443', '9080-9085', 'mock').
                               Default: 'mock' (9080, 9081, 9432, 9379, 9022, 9843, 9999).
  --timeout <seconds>          Connection timeout in seconds (default: 1).
  -m, --markdown               Output formatted Markdown table.
  -j, --json                   Output results as JSON.
  --no-fail                    Always return exit code 0.
  -h, --help                   Display this help message and exit.

Examples:
  $(basename "$0") -t 127.0.0.1 -p 9080,9081,9432,9379,9022
  $(basename "$0") -f targets.txt --markdown
EOF
}

PORT_SPEC="mock"

# Parse CLI Options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                TARGETS+=("$2")
                shift 2
            else
                echo -e "${RED}Error: --target requires a value${NC}" >&2
                exit 3
            fi
            ;;
        -f|--file)
            if [[ -n "${2:-}" && -f "$2" ]]; then
                while IFS= read -r line || [[ -n "$line" ]]; do
                    cleaned=$(echo "$line" | sed 's/#.*//' | tr -d ' \r\t')
                    if [[ -n "$cleaned" ]]; then
                        TARGETS+=("$cleaned")
                    fi
                done < "$2"
                shift 2
            else
                echo -e "${RED}Error: File not found: ${2:-}${NC}" >&2
                exit 3
            fi
            ;;
        -p|--ports)
            PORT_SPEC="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -m|--markdown)
            MARKDOWN_OUTPUT=1
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

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("127.0.0.1")
fi

# Parse Port Specification
if [[ "$PORT_SPEC" == "mock" ]]; then
    PORTS=(9080 9081 9432 9379 9022 9843 9999)
elif [[ "$PORT_SPEC" == "web" ]]; then
    PORTS=(80 443 8080 8443 9080 9081 9843)
elif [[ "$PORT_SPEC" == "db" ]]; then
    PORTS=(3306 5432 6379 9432 9379 27017)
else
    IFS=',' read -ra ADDR <<< "$PORT_SPEC"
    for item in "${ADDR[@]}"; do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start_p="${BASH_REMATCH[1]}"
            end_p="${BASH_REMATCH[2]}"
            for ((p=start_p; p<=end_p; p++)); do
                PORTS+=("$p")
            done
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            PORTS+=("$item")
        fi
    done
fi

# Function to test TCP connection
check_port() {
    local host="$1"
    local port="$2"
    local timeout="$3"

    # Attempt connection with /dev/tcp or nc
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w "$timeout" "$host" "$port" 2>/dev/null; then
            echo "OPEN"
            return 0
        else
            echo "CLOSED"
            return 1
        fi
    else
        # Fallback to bash /dev/tcp subshell
        if timeout "$timeout" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
            echo "OPEN"
            return 0
        else
            echo "CLOSED"
            return 1
        fi
    fi
}

OPEN_COUNT=0
CLOSED_COUNT=0
TOTAL_COUNT=0

if [[ $JSON_OUTPUT -eq 0 && $MARKDOWN_OUTPUT -eq 0 ]]; then
    echo -e "\n${BOLD}${BLUE}========================================================================================================${NC}"
    echo -e "${BOLD}                     NETWORK PORT SCANNER & TROUBLESHOOTER (POSIX/BASH)                                 ${NC}"
    echo -e "${BOLD}${BLUE}========================================================================================================${NC}\n"
    printf "${BOLD}%-10s  %-20s  %-6s  %-14s${NC}\n" "STATE" "TARGET HOST" "PORT" "SERVICE"
    echo -e "${DIM}--------------------------------------------------------------------------------------------------------${NC}"
elif [[ $MARKDOWN_OUTPUT -eq 1 ]]; then
    echo "# Network Port Scan Report (Bash Edition)"
    echo
    echo "| Host | Port | Service | State |"
    echo "| :--- | :--- | :--- | :--- |"
fi

for host in "${TARGETS[@]}"; do
    for port in "${PORTS[@]}"; do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        service_name=$(get_service_name "$port")
        state=$(check_port "$host" "$port" "$TIMEOUT")

        if [[ "$state" == "OPEN" ]]; then
            OPEN_COUNT=$((OPEN_COUNT + 1))
            badge="${GREEN}[ OPEN  ]${NC}"
        else
            CLOSED_COUNT=$((CLOSED_COUNT + 1))
            badge="${DIM}[CLOSED ]${NC}"
        fi

        if [[ $JSON_OUTPUT -eq 0 && $MARKDOWN_OUTPUT -eq 0 ]]; then
            printf "%b  %-20s  %-6s  %-14s\n" "$badge" "$host" "$port" "$service_name"
        elif [[ $MARKDOWN_OUTPUT -eq 1 ]]; then
            echo "| \`$host\` | \`$port\` | \`$service_name\` | **\`$state\`** |"
        fi
    done
done

if [[ $JSON_OUTPUT -eq 0 && $MARKDOWN_OUTPUT -eq 0 ]]; then
    echo -e "${DIM}--------------------------------------------------------------------------------------------------------${NC}"
    echo -e "\n${BOLD}SUMMARY STATISTICS:${NC}"
    echo -e "  Total Probes : ${BOLD}${TOTAL_COUNT}${NC}"
    echo -e "  ${GREEN}✔ OPEN Ports   ${NC}: ${OPEN_COUNT}"
    echo -e "  ${DIM}○ CLOSED Ports ${NC}: ${CLOSED_COUNT}\n"
elif [[ $JSON_OUTPUT -eq 1 ]]; then
    cat << EOF
{
  "summary": {
    "total": $TOTAL_COUNT,
    "open": $OPEN_COUNT,
    "closed": $CLOSED_COUNT
  }
}
EOF
fi

if [[ $NO_FAIL -eq 1 ]]; then
    exit 0
fi

exit 0
