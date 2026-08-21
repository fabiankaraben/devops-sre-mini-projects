#!/usr/bin/env bash
# ==============================================================================
# Script Name: cleanup_users.sh
# Description: Rollback & Environment Reset Script for User Batch Provisioner.
#              Reads the CSV manifest and cleanly deletes provisioned users,
#              removes home directories, purges secondary groups, and removes
#              sudoers drop-in configuration files.
# ==============================================================================

set -euo pipefail

MANIFEST_PATH="users_manifest.csv"
DRY_RUN=false
JSON_OUTPUT=false
PRETTY_PRINT=false

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Cleanup & Rollback Utility for User Batch Provisioner.
Deletes users, home directories, groups, and sudoers configurations created from a manifest.

Options:
  -m, --manifest <file>     Path to the CSV user manifest (default: users_manifest.csv)
  --dry-run                 Simulate cleanup without deleting accounts or files
  --json                    Output cleanup summary in JSON format
  --pretty                  Format JSON report with 2-space indentation
  -h, --help                Display this help message and exit

Example:
  $(basename "$0") --manifest ./users_manifest.csv
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--manifest)
                [[ $# -lt 2 ]] && { echo "Missing value for --manifest" >&2; exit 2; }
                MANIFEST_PATH="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --pretty)
                PRETTY_PRINT=true
                JSON_OUTPUT=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 2
                ;;
        esac
    done

    if [[ ! -f "$MANIFEST_PATH" ]]; then
        echo "Manifest file '${MANIFEST_PATH}' not found." >&2
        exit 2
    fi

    if [[ "$DRY_RUN" == false && "$(id -u)" -ne 0 ]]; then
        echo "This script must be executed with root/sudo privileges to remove users and groups." >&2
        exit 2
    fi
}

main() {
    parse_args "$@"

    local deleted_users=()
    local deleted_groups=()
    local deleted_sudoers=()
    local groups_to_check=()

    # Parse CSV into Unit Separator (\x1f) delimited rows safely handling quotes, commas, and empty fields
    local parsed_rows=()
    if command -v python3 >/dev/null 2>&1; then
        while IFS= read -r row; do
            [[ -n "$row" ]] && parsed_rows+=("$row")
        done < <(python3 -c 'import csv, sys; [print("\x1f".join(row)) for row in csv.reader(sys.stdin) if row and not row[0].startswith("#")]' < "$MANIFEST_PATH")
    else
        while IFS= read -r row; do
            [[ -n "$row" ]] && parsed_rows+=("$row")
        done < "$MANIFEST_PATH"
    fi

    local line_num=0
    for line in "${parsed_rows[@]}"; do
        line_num=$(( line_num + 1 ))
        if [[ $line_num -eq 1 && "$line" =~ username ]]; then
            continue
        fi

        local username primary_group secondary_groups shell sudo_access status ssh_public_key
        IFS=$'\x1f' read -r username primary_group secondary_groups shell sudo_access status ssh_public_key <<< "$line"

        username=$(echo "$username" | tr -d '"' | xargs)
        primary_group=$(echo "$primary_group" | tr -d '"' | xargs)
        secondary_groups=$(echo "$secondary_groups" | tr -d '"' | xargs)

        [[ -z "$username" ]] && continue
        [[ -n "$primary_group" ]] && groups_to_check+=("$primary_group")

        if [[ -n "$secondary_groups" ]]; then
            IFS=',' read -ra sec_array <<< "$secondary_groups"
            for g in "${sec_array[@]}"; do
                g=$(echo "$g" | xargs)
                [[ -n "$g" ]] && groups_to_check+=("$g")
            done
        fi

        # Check if user exists on system
        if id -u "$username" >/dev/null 2>&1; then
            if [[ "$DRY_RUN" == true ]]; then
                deleted_users+=("{\"username\": \"${username}\", \"action\": \"dry-run-delete\"}")
            else
                userdel -r -f "$username" 2>/dev/null || userdel -f "$username" 2>/dev/null || true
                rm -rf "/home/${username}" 2>/dev/null || true
                deleted_users+=("{\"username\": \"${username}\", \"action\": \"deleted\"}")
            fi
        fi

        # Remove sudoers file
        local sudoers_file="/etc/sudoers.d/99-user-${username}"
        if [[ -f "$sudoers_file" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                deleted_sudoers+=("{\"file\": \"${sudoers_file}\", \"action\": \"dry-run-remove\"}")
            else
                rm -f "$sudoers_file"
                deleted_sudoers+=("{\"file\": \"${sudoers_file}\", \"action\": \"removed\"}")
            fi
        fi
    done < "$MANIFEST_PATH"

    # Remove candidate groups if they exist and are not standard system groups (like root, daemon, bin, sudo, docker)
    local protected_groups=("root" "daemon" "bin" "sys" "adm" "tty" "disk" "sudo" "docker" "wheel" "staff")
    for grp in "${groups_to_check[@]}"; do
        # Check if protected
        local is_protected=false
        for p in "${protected_groups[@]}"; do
            if [[ "$grp" == "$p" ]]; then
                is_protected=true
                break
            fi
        done

        if [[ "$is_protected" == false ]]; then
            if getent group "$grp" >/dev/null 2>&1 || grep -q "^${grp}:" /etc/group 2>/dev/null; then
                if [[ "$DRY_RUN" == true ]]; then
                    deleted_groups+=("{\"group\": \"${grp}\", \"action\": \"dry-run-delete\"}")
                else
                    groupdel "$grp" 2>/dev/null || true
                    deleted_groups+=("{\"group\": \"${grp}\", \"action\": \"deleted\"}")
                fi
            fi
        fi
    done

    local json_report
    json_report=$(cat <<EOF
{
  "status": "CLEANUP_SUCCESS",
  "manifest": "${MANIFEST_PATH}",
  "dry_run": ${DRY_RUN},
  "summary": {
    "users_removed": ${#deleted_users[@]},
    "groups_removed": ${#deleted_groups[@]},
    "sudoers_removed": ${#deleted_sudoers[@]}
  }
}
EOF
)

    if [[ "$JSON_OUTPUT" == true ]]; then
        if [[ "$PRETTY_PRINT" == true ]] && command -v jq >/dev/null 2>&1; then
            echo "$json_report" | jq .
        else
            echo "$json_report"
        fi
    else
        echo "=================================================="
        echo "  Cleanup & Rollback Complete"
        echo "=================================================="
        echo "Users Removed   : ${#deleted_users[@]}"
        echo "Groups Removed  : ${#deleted_groups[@]}"
        echo "Sudoers Removed : ${#deleted_sudoers[@]}"
        echo "=================================================="
    fi
}

main "$@"
