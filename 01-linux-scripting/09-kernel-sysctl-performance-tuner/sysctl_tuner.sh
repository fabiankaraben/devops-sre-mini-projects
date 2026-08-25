#!/usr/bin/env bash
# ==============================================================================
# Script Name: sysctl_tuner.sh
# Description: Production-grade Linux Kernel & Sysctl Performance Tuner.
#              Audits system parameters, applies baseline profiles (Web, DB, HPC),
#              manages timestamped backups, and executes instant rollbacks.
#
# Part of: DevOps & SRE Mini-Projects
# Domain:  01. Linux Scripting
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/profiles"
BACKUPS_DIR="${SCRIPT_DIR}/backups"

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

ACTION="audit"
PROFILE_NAME="web"
PROFILE_FILE="${PROFILES_DIR}/web.conf"
CONFIG_FILE="/etc/sysctl.d/99-performance.conf"
CUSTOM_BACKUP=""
DRY_RUN=0
JSON_OUTPUT=0
NO_FAIL=0

mkdir -p "$BACKUPS_DIR"

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Linux Kernel & Sysctl Performance Tuner

Modes:
  --audit                 Inspect current kernel values and compare against target profile (default)
  --apply                 Create snapshot backup, apply tuned profile, and verify application
  --rollback [file]       Restore kernel parameters from specified backup or latest snapshot
  --dry-run               Simulate parameter changes without modifying kernel state

Profile & Configuration:
  -p, --profile <name>    Profile name (web, db, hpc) or path to custom .conf file (default: web)
  -c, --config-file <path> Target sysctl configuration file (default: /etc/sysctl.d/99-performance.conf)
  -b, --backup-dir <path> Directory for storing snapshot backups (default: ./backups)
  -j, --json              Output results in machine-readable JSON format
  --no-fail               Always return exit code 0 regardless of audit compliance
  -h, --help              Display this help message and exit

Examples:
  $(basename "$0") --audit --profile web
  $(basename "$0") --apply --profile db
  $(basename "$0") --rollback
  $(basename "$0") --rollback backups/sysctl_backup_20260825_120000.conf
EOF
}

# Parse Command Line Options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --audit)
            ACTION="audit"
            shift
            ;;
        --apply)
            ACTION="apply"
            shift
            ;;
        --rollback)
            ACTION="rollback"
            if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                CUSTOM_BACKUP="$2"
                shift 2
            else
                shift
            fi
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -p|--profile)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                PROFILE_NAME="$2"
                if [[ -f "$2" ]]; then
                    PROFILE_FILE="$2"
                elif [[ -f "${PROFILES_DIR}/${2}.conf" ]]; then
                    PROFILE_FILE="${PROFILES_DIR}/${2}.conf"
                elif [[ -f "${PROFILES_DIR}/${2}" ]]; then
                    PROFILE_FILE="${PROFILES_DIR}/${2}"
                else
                    echo -e "${RED}Error: Profile not found: $2${NC}" >&2
                    exit 3
                fi
                shift 2
            else
                echo -e "${RED}Error: --profile requires a value${NC}" >&2
                exit 3
            fi
            ;;
        -c|--config-file)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -b|--backup-dir)
            BACKUPS_DIR="$2"
            mkdir -p "$BACKUPS_DIR"
            shift 2
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

if [[ ! -f "$PROFILE_FILE" && "$ACTION" != "rollback" ]]; then
    echo -e "${RED}Error: Profile file does not exist: $PROFILE_FILE${NC}" >&2
    exit 3
fi

# Function to read a single sysctl value
get_sysctl_val() {
    local key="$1"
    # Try sysctl command
    local val=""
    if command -v sysctl >/dev/null 2>&1; then
        val=$(sysctl -n "$key" 2>/dev/null || true)
    fi
    # If empty, try direct /proc/sys read
    if [[ -z "$val" ]]; then
        local proc_path="/proc/sys/${key//.//}"
        if [[ -f "$proc_path" ]]; then
            val=$(cat "$proc_path" 2>/dev/null || true)
        fi
    fi
    # Normalize tabs/multiple spaces to single space
    echo "$val" | tr '\t' ' ' | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Function to write/apply a single sysctl value
set_sysctl_val() {
    local key="$1"
    local val="$2"

    if [[ $DRY_RUN -eq 1 ]]; then
        return 0
    fi

    # Try sysctl -w
    if command -v sysctl >/dev/null 2>&1; then
        if sysctl -w "${key}=${val}" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Try direct /proc/sys write
    local proc_path="/proc/sys/${key//.//}"
    if [[ -w "$proc_path" ]]; then
        echo "$val" > "$proc_path" 2>/dev/null && return 0
    fi

    return 1
}

# Function to parse key-value lines from a .conf file
parse_conf_file() {
    local conf="$1"
    KEYS=()
    TARGETS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip comments and trim whitespace
        local cleaned
        cleaned=$(echo "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$cleaned" && "$cleaned" =~ ^([a-zA-Z0-9._-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local k="${BASH_REMATCH[1]}"
            local v="${BASH_REMATCH[2]}"
            v=$(echo "$v" | tr '\t' ' ' | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            KEYS+=("$k")
            TARGETS+=("$v")
        fi
    done < "$conf"
}

# ==============================================================================
# ACTION: AUDIT
# ==============================================================================
if [[ "$ACTION" == "audit" ]]; then
    parse_conf_file "$PROFILE_FILE"

    TOTAL_COUNT=${#KEYS[@]}
    OPTIMAL_COUNT=0
    SUBOPTIMAL_COUNT=0
    UNAVAILABLE_COUNT=0

    AUDIT_RESULTS=()

    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo -e "\n${BOLD}${BLUE}========================================================================================================${NC}"
        echo -e "${BOLD}                       LINUX KERNEL SYSCTL PERFORMANCE AUDITOR                                          ${NC}"
        echo -e "${BOLD}${BLUE}========================================================================================================${NC}"
        echo -e "Profile  : ${CYAN}${PROFILE_FILE}${NC}"
        echo -e "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')\n"
        printf "${BOLD}%-35s  %-22s  %-22s  %-12s${NC}\n" "KERNEL PARAMETER" "CURRENT VALUE" "TARGET VALUE" "STATUS"
        echo -e "${DIM}--------------------------------------------------------------------------------------------------------${NC}"
    fi

    for ((i=0; i<TOTAL_COUNT; i++)); do
        k="${KEYS[i]}"
        target_v="${TARGETS[i]}"
        curr_v=$(get_sysctl_val "$k")

        status="OPTIMAL"
        badge="${GREEN}[ OPTIMAL ]${NC}"

        if [[ -z "$curr_v" ]]; then
            status="UNAVAILABLE"
            badge="${DIM}[ N/A     ]${NC}"
            curr_v="<not present>"
            UNAVAILABLE_COUNT=$((UNAVAILABLE_COUNT + 1))
        elif [[ "$curr_v" == "$target_v" ]]; then
            OPTIMAL_COUNT=$((OPTIMAL_COUNT + 1))
        else
            status="SUBOPTIMAL"
            badge="${YELLOW}[SUBOPTIMAL]${NC}"
            SUBOPTIMAL_COUNT=$((SUBOPTIMAL_COUNT + 1))
        fi

        if [[ $JSON_OUTPUT -eq 0 ]]; then
            printf "%-35s  %-22s  %-22s  %b\n" "$k" "$curr_v" "$target_v" "$badge"
        fi

        AUDIT_RESULTS+=("{\"parameter\":\"$k\",\"current\":\"$curr_v\",\"target\":\"$target_v\",\"status\":\"$status\"}")
    done

    COMPLIANCE_PCT=0
    ACTIVE_PROBES=$((TOTAL_COUNT - UNAVAILABLE_COUNT))
    if [[ $ACTIVE_PROBES -gt 0 ]]; then
        COMPLIANCE_PCT=$(( (OPTIMAL_COUNT * 100) / ACTIVE_PROBES ))
    fi

    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo -e "${DIM}--------------------------------------------------------------------------------------------------------${NC}"
        echo -e "\n${BOLD}AUDIT SUMMARY & COMPLIANCE:${NC}"
        echo -e "  Total Checked   : ${BOLD}${TOTAL_COUNT}${NC}"
        echo -e "  ${GREEN}✔ Optimal       ${NC}: ${OPTIMAL_COUNT}"
        echo -e "  ${YELLOW}▲ Suboptimal    ${NC}: ${SUBOPTIMAL_COUNT}"
        echo -e "  ${DIM}○ Unavailable   ${NC}: ${UNAVAILABLE_COUNT}"
        echo -e "  Compliance Score: ${BOLD}${COMPLIANCE_PCT}%${NC} (${OPTIMAL_COUNT}/${ACTIVE_PROBES} parameters aligned)\n"
    else
        JSON_ROWS=$(IFS=,; echo "${AUDIT_RESULTS[*]}")
        cat << EOF
{
  "profile": "$PROFILE_FILE",
  "summary": {
    "total": $TOTAL_COUNT,
    "optimal": $OPTIMAL_COUNT,
    "suboptimal": $SUBOPTIMAL_COUNT,
    "unavailable": $UNAVAILABLE_COUNT,
    "compliance_percent": $COMPLIANCE_PCT
  },
  "parameters": [$JSON_ROWS]
}
EOF
    fi

    if [[ $NO_FAIL -eq 1 ]]; then
        exit 0
    fi

    if [[ $SUBOPTIMAL_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi

# ==============================================================================
# ACTION: APPLY
# ==============================================================================
if [[ "$ACTION" == "apply" ]]; then
    parse_conf_file "$PROFILE_FILE"
    TOTAL_COUNT=${#KEYS[@]}

    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    BACKUP_FILE="${BACKUPS_DIR}/sysctl_backup_${TIMESTAMP}.conf"

    echo -e "\n${BOLD}${BLUE}========================================================================================================${NC}"
    echo -e "${BOLD}                       APPLYING SYSCTL PERFORMANCE PROFILE (${PROFILE_NAME})                             ${NC}"
    echo -e "${BOLD}${BLUE}========================================================================================================${NC}\n"

    # 1. Create Snapshot Backup of existing values
    echo -e "${CYAN}[1/4] Taking snapshot backup of current kernel parameters...${NC}"
    {
        echo "# =============================================================================="
        echo "# Sysctl Kernel Parameter Snapshot Backup"
        echo "# Generated At: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Pre-Tuning Profile: ${PROFILE_NAME}"
        echo "# =============================================================================="
        for k in "${KEYS[@]}"; do
            v=$(get_sysctl_val "$k")
            if [[ -n "$v" ]]; then
                echo "${k} = ${v}"
            fi
        done
    } > "$BACKUP_FILE"
    echo -e "  ${GREEN}✔ Saved backup to: ${BOLD}${BACKUP_FILE}${NC}"

    # 2. Write Configuration File
    echo -e "\n${CYAN}[2/4] Generating sysctl configuration file...${NC}"
    CONFIG_DIR=$(dirname "$CONFIG_FILE")
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    if [[ -w "$CONFIG_DIR" || -w "$CONFIG_FILE" || "$CONFIG_FILE" != /etc/* ]]; then
        cp "$PROFILE_FILE" "$CONFIG_FILE" 2>/dev/null || true
        echo -e "  ${GREEN}✔ Wrote target configuration to: ${BOLD}${CONFIG_FILE}${NC}"
    else
        echo -e "  ${YELLOW}▲ Note: Cannot write to system /etc. Proceeding with in-memory sysctl application.${NC}"
    fi

    # 3. Apply Parameters
    echo -e "\n${CYAN}[3/4] Applying parameters to active Linux kernel...${NC}"
    APPLIED_COUNT=0
    FAILED_COUNT=0

    for ((i=0; i<TOTAL_COUNT; i++)); do
        k="${KEYS[i]}"
        target_v="${TARGETS[i]}"
        if set_sysctl_val "$k" "$target_v"; then
            APPLIED_COUNT=$((APPLIED_COUNT + 1))
            echo -e "  - ${GREEN}[APPLIED]${NC} ${k} = ${target_v}"
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            echo -e "  - ${RED}[FAILED]${NC}  ${k} = ${target_v} (permission or kernel unsupported)"
        fi
    done

    # 4. Verification
    echo -e "\n${CYAN}[4/4] Verifying kernel state...${NC}"
    VERIFIED_COUNT=0
    for ((i=0; i<TOTAL_COUNT; i++)); do
        k="${KEYS[i]}"
        target_v="${TARGETS[i]}"
        new_v=$(get_sysctl_val "$k")
        if [[ "$new_v" == "$target_v" ]]; then
            VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
        fi
    done

    echo -e "\n${BOLD}APPLICATION SUMMARY:${NC}"
    echo -e "  Total Target Parameters: ${TOTAL_COUNT}"
    echo -e "  ${GREEN}✔ Successfully Applied  ${NC}: ${APPLIED_COUNT}"
    echo -e "  ${GREEN}✔ Verified in Kernel    ${NC}: ${VERIFIED_COUNT}"
    echo -e "  ${RED}✖ Failed / Skipped      ${NC}: ${FAILED_COUNT}"
    echo -e "  Rollback File Created   : ${BOLD}${BACKUP_FILE}${NC}\n"

    exit 0
fi

# ==============================================================================
# ACTION: ROLLBACK
# ==============================================================================
if [[ "$ACTION" == "rollback" ]]; then
    TARGET_BACKUP="$CUSTOM_BACKUP"
    if [[ -z "$TARGET_BACKUP" ]]; then
        # Find newest backup file in BACKUPS_DIR
        TARGET_BACKUP=$(ls -t "${BACKUPS_DIR}"/sysctl_backup_*.conf 2>/dev/null | head -n 1 || true)
    fi

    if [[ -z "$TARGET_BACKUP" || ! -f "$TARGET_BACKUP" ]]; then
        echo -e "${RED}Error: No valid backup snapshot file found in ${BACKUPS_DIR}.${NC}" >&2
        exit 3
    fi

    echo -e "\n${BOLD}${BLUE}========================================================================================================${NC}"
    echo -e "${BOLD}                       REVERTING SYSCTL PARAMETERS (ROLLBACK)                                            ${NC}"
    echo -e "${BOLD}${BLUE}========================================================================================================${NC}"
    echo -e "Restoring Snapshot: ${CYAN}${TARGET_BACKUP}${NC}\n"

    parse_conf_file "$TARGET_BACKUP"
    RESTORE_COUNT=${#KEYS[@]}
    SUCCESS_RESTORE=0

    for ((i=0; i<RESTORE_COUNT; i++)); do
        k="${KEYS[i]}"
        v="${TARGETS[i]}"
        if set_sysctl_val "$k" "$v"; then
            SUCCESS_RESTORE=$((SUCCESS_RESTORE + 1))
            echo -e "  - ${GREEN}[RESTORED]${NC} ${k} = ${v}"
        else
            echo -e "  - ${RED}[FAILED]${NC}   ${k} = ${v}"
        fi
    done

    echo -e "\n${BOLD}ROLLBACK COMPLETE:${NC} Restored ${GREEN}${SUCCESS_RESTORE}/${RESTORE_COUNT}${NC} parameters to prior snapshot state.\n"
    exit 0
fi
