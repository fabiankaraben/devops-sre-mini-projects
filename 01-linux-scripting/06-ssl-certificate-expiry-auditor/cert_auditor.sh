#!/usr/bin/env bash
# ==============================================================================
# Script Name: cert_auditor.sh
# Description: Pure POSIX / Bash SSL/TLS Certificate Expiry Auditor using OpenSSL.
#              Audits TLS endpoints, extracts certificate expiration dates,
#              and reports status (OK, WARNING, CRITICAL, EXPIRED, ERROR).
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -uo pipefail

# ANSI Color Codes
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BOLD_RED="\033[1;31m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
BOLD="\033[1m"
DIM="\033[2m"
NC="\033[0m"

WARNING_DAYS=30
CRITICAL_DAYS=7
TIMEOUT=5
JSON_OUTPUT=0
NO_FAIL=0
TARGETS=()

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

SSL/TLS Certificate Expiry Auditor (Bash/OpenSSL Edition)

Options:
  -t, --target <host:port>     Target endpoint to audit (e.g. google.com:443, localhost:8443).
                               Can be specified multiple times.
  -f, --file <path>            File containing list of targets (one per line).
  -w, --warning-days <days>    Warning threshold in days (default: 30).
  -c, --critical-days <days>   Critical threshold in days (default: 7).
  --timeout <seconds>          Connection timeout in seconds (default: 5).
  -k, --insecure               Allow self-signed or unverified certificates (default in test mode).
  -j, --json                   Output results as JSON.
  --no-fail                    Always return exit code 0.
  -h, --help                   Display this help message and exit.

Examples:
  $(basename "$0") -t localhost:8443 -t localhost:8444 -t localhost:8445
  $(basename "$0") -f targets.txt --json
EOF
}

# Parse Command Line Arguments
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
        -w|--warning-days)
            WARNING_DAYS="$2"
            shift 2
            ;;
        -c|--critical-days)
            CRITICAL_DAYS="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -k|--insecure)
            # Accepted for compatibility with python tool
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
    echo -e "${RED}Error: No targets specified. Use -t <target> or -f <file>.${NC}" >&2
    usage >&2
    exit 3
fi

parse_date_to_epoch() {
    local str="$1"
    local cleaned
    cleaned=$(echo "$str" | tr -s ' ')
    
    # 1. GNU date
    local epoch
    if epoch=$(date -d "$cleaned" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi

    # 2. BSD date (macOS)
    if epoch=$(date -j -u -f "%b %d %T %Y %Z" "$cleaned" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi
    if epoch=$(date -j -u -f "%b %e %T %Y %Z" "$cleaned" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi

    # 3. Python fallback
    if command -v python3 >/dev/null 2>&1; then
        if epoch=$(python3 -c "from datetime import datetime; import sys; dt = datetime.strptime(' '.join(sys.argv[1].split()), '%b %d %H:%M:%S %Y %Z'); print(int(dt.timestamp()))" "$str" 2>/dev/null); then
            echo "$epoch"
            return 0
        fi
    fi

    return 1
}

# Audit State
TOTAL_COUNT=0
OK_COUNT=0
WARN_COUNT=0
CRIT_COUNT=0
EXP_COUNT=0
ERR_COUNT=0

RESULTS_JSON="[]"

if [[ $JSON_OUTPUT -eq 0 ]]; then
    echo -e "\n${BOLD}${BLUE}========================================================================================================${NC}"
    echo -e "${BOLD}                     SSL/TLS CERTIFICATE EXPIRY AUDITOR (POSIX/BASH)                                    ${NC}"
    echo -e "${BOLD}${BLUE}========================================================================================================${NC}"
    echo -e "Thresholds : ${YELLOW}Warning <= ${WARNING_DAYS} days${NC} | ${RED}Critical <= ${CRITICAL_DAYS} days${NC}\n"
    printf "${BOLD}%-10s  %-26s  %-20s  %-19s  %-10s${NC}\n" "STATUS" "TARGET ENDPOINT" "ISSUER" "VALID UNTIL (UTC)" "DAYS LEFT"
    echo -e "${DIM}--------------------------------------------------------------------------------------------------------${NC}"
fi

NOW_EPOCH=$(date +%s)

for target in "${TARGETS[@]}"; do
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    
    # Parse target string
    sni_override=""
    if [[ "$target" == *"@"* ]]; then
        sni_override="${target#*@}"
        target="${target%@*}"
    fi

    # Remove http/https
    clean_target=$(echo "$target" | sed -E 's#^https?://##' | cut -d/ -f1)

    if [[ "$clean_target" == *":"* ]]; then
        host="${clean_target%:*}"
        port="${clean_target##*:}"
    else
        host="$clean_target"
        port="443"
    fi

    sni="${sni_override:-$host}"

    # Extract certificate using OpenSSL
    cert_raw=$(echo | openssl s_client -connect "${host}:${port}" -servername "${sni}" 2>/dev/null | openssl x509 -noout -dates -subject -issuer 2>/dev/null || true)

    if [[ -z "$cert_raw" || ! "$cert_raw" =~ "notAfter=" ]]; then
        ERR_COUNT=$((ERR_COUNT + 1))
        if [[ $JSON_OUTPUT -eq 0 ]]; then
            printf "${MAGENTA}%-10s${NC}  %-26s  ${RED}%-50s${NC}\n" "[ ERROR ]" "${host}:${port}" "Connection failed / TLS handshake error"
        fi
        continue
    fi

    not_after_raw=$(echo "$cert_raw" | grep "notAfter=" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//')
    subject_raw=$(echo "$cert_raw" | grep "subject=" | head -n1 | cut -d= -f2-)
    issuer_raw=$(echo "$cert_raw" | grep "issuer=" | head -n1 | cut -d= -f2-)

    # Extract CN or Org
    cn=$(echo "$subject_raw" | grep -o 'CN *= *[^,]*' | cut -d= -f2 | sed 's/^[[:space:]]*//' || echo "$host")
    issuer_org=$(echo "$issuer_raw" | grep -o 'O *= *[^,]*' | cut -d= -f2 | sed 's/^[[:space:]]*//' || echo "")
    if [[ -z "$issuer_org" ]]; then
        issuer_org=$(echo "$issuer_raw" | grep -o 'CN *= *[^,]*' | cut -d= -f2 | sed 's/^[[:space:]]*//' || echo "Unknown")
    fi

    # Calculate Days Left
    exp_epoch=$(parse_date_to_epoch "$not_after_raw" || echo "")

    if [[ -z "$exp_epoch" ]]; then
        ERR_COUNT=$((ERR_COUNT + 1))
        if [[ $JSON_OUTPUT -eq 0 ]]; then
            printf "${MAGENTA}%-10s${NC}  %-26s  ${RED}%-50s${NC}\n" "[ ERROR ]" "${host}:${port}" "Date parsing failed: ${not_after_raw}"
        fi
        continue
    fi

    diff_seconds=$((exp_epoch - NOW_EPOCH))
    days_left=$((diff_seconds / 86400))

    # Determine Status
    status="OK"
    if [[ $days_left -le 0 ]]; then
        status="EXPIRED"
        EXP_COUNT=$((EXP_COUNT + 1))
    elif [[ $days_left -le $CRITICAL_DAYS ]]; then
        status="CRITICAL"
        CRIT_COUNT=$((CRIT_COUNT + 1))
    elif [[ $days_left -le $WARNING_DAYS ]]; then
        status="WARNING"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        status="OK"
        OK_COUNT=$((OK_COUNT + 1))
    fi

    # Format Output
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        badge="${GREEN}[  OK   ]${NC}"
        days_str="${GREEN}${days_left} d${NC}"
        if [[ "$status" == "WARNING" ]]; then
            badge="${YELLOW}[ WARN  ]${NC}"
            days_str="${YELLOW}${days_left} d${NC}"
        elif [[ "$status" == "CRITICAL" ]]; then
            badge="${RED}[ CRIT  ]${NC}"
            days_str="${RED}${days_left} d${NC}"
        elif [[ "$status" == "EXPIRED" ]]; then
            badge="${BOLD_RED}[EXPIRED]${NC}"
            days_str="${BOLD_RED}${days_left} d${NC}"
        fi

        # Truncate strings for clean formatting
        display_target="${host}:${port}"
        display_issuer="${issuer_org:0:20}"
        display_expiry="${not_after_raw:0:19}"

        printf "%b  %-26s  %-20s  %-19s  %b\n" "$badge" "$display_target" "$display_issuer" "$display_expiry" "$days_str"
    fi
done

if [[ $JSON_OUTPUT -eq 0 ]]; then
    echo -e "${DIM}--------------------------------------------------------------------------------------------------------${NC}"
    echo -e "\n${BOLD}SUMMARY STATISTICS:${NC}"
    echo -e "  Total Audited : ${BOLD}${TOTAL_COUNT}${NC}"
    echo -e "  ${GREEN}✔ Healthy (OK)${NC}   : ${OK_COUNT}"
    echo -e "  ${YELLOW}▲ Expiring Soon${NC} : ${WARN_COUNT}"
    echo -e "  ${RED}✖ Critical/Exp${NC}  : $((CRIT_COUNT + EXP_COUNT)) (Critical: ${CRIT_COUNT}, Expired: ${EXP_COUNT})"
    echo -e "  ${MAGENTA}⚠ Errors/Unreach${NC}: ${ERR_COUNT}\n"
else
    # Simple JSON summary output
    cat << EOF
{
  "summary": {
    "total": $TOTAL_COUNT,
    "healthy": $OK_COUNT,
    "warning": $WARN_COUNT,
    "critical": $CRIT_COUNT,
    "expired": $EXP_COUNT,
    "errors": $ERR_COUNT
  }
}
EOF
fi

if [[ $NO_FAIL -eq 1 ]]; then
    exit 0
fi

if [[ $((CRIT_COUNT + EXP_COUNT)) -gt 0 ]]; then
    exit 2
fi
if [[ $WARN_COUNT -gt 0 ]]; then
    exit 1
fi
if [[ $ERR_COUNT -gt 0 ]]; then
    exit 3
fi

exit 0
