#!/usr/bin/env bash
# ==============================================================================
# Script Name: provision_users.sh
# Description: Production-grade Idempotent User & Group Batch Provisioner.
#              Reads a declarative CSV manifest, provisions Linux accounts,
#              manages primary/secondary groups, configures secure SSH keys
#              with strict permissions (0700/0600), configures sudoers safely,
#              and handles account deactivation.
#
# Exit Codes:
#   0 - Success: All users/groups provisioned or updated idempotently.
#   1 - Partial Failure: One or more users could not be provisioned.
#   2 - Fatal Error: Manifest missing, invalid argument, or insufficient privileges.
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"

# Defaults
MANIFEST_PATH="users_manifest.csv"
DRY_RUN=false
JSON_OUTPUT=false
PRETTY_PRINT=false

# ------------------------------------------------------------------------------
# Usage & Help
# ------------------------------------------------------------------------------

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

User and Group Batch Provisioner (DevOps / SRE Mini-Project)
Automates idempotent account onboarding and access control from a CSV manifest.

Options:
  -m, --manifest <file>     Path to the CSV user manifest (default: users_manifest.csv)
  --dry-run                 Simulate provisioning actions without modifying system state
  --json                    Output execution report in JSON format
  --pretty                  Format JSON report with 2-space indentation
  -h, --help                Display this help message and exit
  -v, --version             Display version information and exit

CSV Manifest Format:
  username,primary_group,secondary_groups,shell,sudo_access,status,ssh_public_key

Example:
  $(basename "$0") --manifest ./users_manifest.csv --json --pretty
  $(basename "$0") --dry-run
EOF
}

print_error() {
    local msg="$1"
    if [[ "$JSON_OUTPUT" == true ]]; then
        echo "{\"error\": \"${msg}\", \"status\": \"ERROR\", \"exit_code\": 2}" >&2
    else
        echo "[ERROR] ${msg}" >&2
    fi
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--manifest)
                [[ $# -lt 2 ]] && { print_error "Missing value for --manifest"; exit 2; }
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
            -v|--version)
                echo "provision_users.sh version ${VERSION}"
                exit 0
                ;;
            *)
                print_error "Unrecognized option: '$1'. Use --help for usage."
                exit 2
                ;;
        esac
    done

    if [[ ! -f "$MANIFEST_PATH" ]]; then
        print_error "Manifest file '${MANIFEST_PATH}' not found"
        exit 2
    fi

    # Root privilege check (only required when not in dry-run mode)
    if [[ "$DRY_RUN" == false && "$(id -u)" -ne 0 ]]; then
        print_error "This script must be executed with root/sudo privileges to manage users and groups."
        exit 2
    fi
}

# ------------------------------------------------------------------------------
# System Helper Functions
# ------------------------------------------------------------------------------

group_exists() {
    local grp="$1"
    getent group "$grp" >/dev/null 2>&1 || grep -q "^${grp}:" /etc/group 2>/dev/null
}

user_exists() {
    local usr="$1"
    id -u "$usr" >/dev/null 2>&1
}

# Find appropriate nologin binary on host
get_nologin_shell() {
    if [[ -x /usr/sbin/nologin ]]; then
        echo "/usr/sbin/nologin"
    elif [[ -x /sbin/nologin ]]; then
        echo "/sbin/nologin"
    elif [[ -x /bin/false ]]; then
        echo "/bin/false"
    else
        echo "/bin/false"
    fi
}

# ------------------------------------------------------------------------------
# Main Provisioning Loop
# ------------------------------------------------------------------------------

main() {
    parse_args "$@"

    local run_timestamp
    run_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local created_users=()
    local updated_users=()
    local deactivated_users=()
    local skipped_users=()
    local errors=()

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
        
        # Skip header if first line
        if [[ $line_num -eq 1 && "$line" =~ username ]]; then
            continue
        fi

        # Extract Unit Separator delimited fields
        local username primary_group secondary_groups shell sudo_access status ssh_public_key
        IFS=$'\x1f' read -r username primary_group secondary_groups shell sudo_access status ssh_public_key <<< "$line"

        # Trim quotes from fields
        username=$(echo "$username" | tr -d '"' | xargs)
        primary_group=$(echo "$primary_group" | tr -d '"' | xargs)
        secondary_groups=$(echo "$secondary_groups" | tr -d '"' | xargs)
        shell=$(echo "$shell" | tr -d '"' | xargs)
        sudo_access=$(echo "$sudo_access" | tr -d '"' | xargs | tr '[:upper:]' '[:lower:]')
        status=$(echo "$status" | tr -d '"' | xargs | tr '[:upper:]' '[:lower:]')
        ssh_public_key=$(echo "$ssh_public_key" | tr -d '"' | xargs)

        # Validate username syntax (POSIX username regex: start with letter/underscore, alphanumeric/hyphen/underscore)
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            errors+=("Line ${line_num}: Invalid username format '${username}'")
            continue
        fi

        # Default fallbacks
        [[ -z "$primary_group" ]] && primary_group="$username"
        [[ -z "$shell" ]] && shell="/bin/bash"
        [[ -z "$status" ]] && status="active"
        [[ -z "$sudo_access" ]] && sudo_access="no"

        if [[ "$DRY_RUN" == true ]]; then
            if [[ "$status" == "inactive" ]]; then
                deactivated_users+=("{\"username\": \"${username}\", \"action\": \"dry-run-deactivate\"}")
            elif user_exists "$username"; then
                updated_users+=("{\"username\": \"${username}\", \"action\": \"dry-run-update\", \"group\": \"${primary_group}\"}")
            else
                created_users+=("{\"username\": \"${username}\", \"action\": \"dry-run-create\", \"group\": \"${primary_group}\"}")
            fi
            continue
        fi

        # ----------------------------------------------------------------------
        # Step 1: Ensure Primary Group Exists
        # ----------------------------------------------------------------------
        if ! group_exists "$primary_group"; then
            groupadd "$primary_group" 2>/dev/null || true
        fi

        # ----------------------------------------------------------------------
        # Step 2: Ensure Secondary Groups Exist
        # ----------------------------------------------------------------------
        if [[ -n "$secondary_groups" ]]; then
            IFS=',' read -ra sec_grp_array <<< "$secondary_groups"
            for sec_grp in "${sec_grp_array[@]}"; do
                sec_grp=$(echo "$sec_grp" | xargs)
                [[ -z "$sec_grp" ]] && continue
                if ! group_exists "$sec_grp"; then
                    groupadd "$sec_grp" 2>/dev/null || true
                fi
            done
        fi

        # ----------------------------------------------------------------------
        # Step 3: Create or Update User Account
        # ----------------------------------------------------------------------
        local user_action=""
        if ! user_exists "$username"; then
            # Create new user
            useradd -m -g "$primary_group" -s "$shell" "$username"
            user_action="created"
            created_users+=("{\"username\": \"${username}\", \"action\": \"created\", \"primary_group\": \"${primary_group}\"}")
        else
            # Update existing user attributes
            usermod -g "$primary_group" -s "$shell" "$username"
            user_action="updated"
            updated_users+=("{\"username\": \"${username}\", \"action\": \"updated\", \"primary_group\": \"${primary_group}\"}")
        fi

        # Add secondary groups if specified
        if [[ -n "$secondary_groups" ]]; then
            usermod -a -G "$secondary_groups" "$username" 2>/dev/null || true
        fi

        # Determine user's home directory
        local user_home
        user_home=$(eval echo "~${username}" 2>/dev/null || echo "/home/${username}")
        if [[ ! -d "$user_home" ]]; then
            mkdir -p "$user_home"
            chown "${username}:${primary_group}" "$user_home"
        fi
        chmod 0750 "$user_home"

        # ----------------------------------------------------------------------
        # Step 4: Configure Secure SSH Keys (0700 dir / 0600 authorized_keys)
        # ----------------------------------------------------------------------
        local ssh_dir="${user_home}/.ssh"
        local auth_keys="${ssh_dir}/authorized_keys"

        mkdir -p "$ssh_dir"
        chmod 0700 "$ssh_dir"
        chown "${username}:${primary_group}" "$ssh_dir"

        if [[ -n "$ssh_public_key" ]]; then
            if [[ ! -f "$auth_keys" ]]; then
                touch "$auth_keys"
            fi
            # Add key idempotently if not already in file
            if ! grep -q -F "$ssh_public_key" "$auth_keys" 2>/dev/null; then
                echo "$ssh_public_key" >> "$auth_keys"
            fi
            chmod 0600 "$auth_keys"
            chown "${username}:${primary_group}" "$auth_keys"
        fi

        # ----------------------------------------------------------------------
        # Step 5: Configure Sudo Privileges
        # ----------------------------------------------------------------------
        local sudoers_file="/etc/sudoers.d/99-user-${username}"
        if [[ "$sudo_access" == "yes" || "$sudo_access" == "true" ]]; then
            # Generate drop-in sudoers entry
            mkdir -p /etc/sudoers.d
            echo "${username} ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
            chmod 0440 "$sudoers_file"

            # Validate syntax with visudo
            if command -v visudo >/dev/null 2>&1; then
                if ! visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
                    rm -f "$sudoers_file"
                    errors+=("User ${username}: Generated sudoers file failed visudo validation and was removed.")
                fi
            fi
        else
            # Ensure sudoers drop-in is removed if user does not have sudo
            rm -f "$sudoers_file" 2>/dev/null || true
        fi

        # ----------------------------------------------------------------------
        # Step 6: Handle Account Deactivation
        # ----------------------------------------------------------------------
        if [[ "$status" == "inactive" || "$status" == "disabled" ]]; then
            local nologin_shell
            nologin_shell=$(get_nologin_shell)
            usermod -s "$nologin_shell" "$username" 2>/dev/null || true
            usermod -L "$username" 2>/dev/null || true
            rm -f "$sudoers_file" 2>/dev/null || true
            deactivated_users+=("{\"username\": \"${username}\", \"action\": \"deactivated\", \"shell\": \"${nologin_shell}\"}")
        fi
    done < "$MANIFEST_PATH"

    # --------------------------------------------------------------------------
    # Output Report
    # --------------------------------------------------------------------------
    local created_json="[]"
    if [[ ${#created_users[@]} -gt 0 ]]; then
        local joined=""
        for item in "${created_users[@]}"; do
            if [[ -z "$joined" ]]; then joined="$item"; else joined="${joined}, $item"; fi
        done
        created_json="[${joined}]"
    fi

    local updated_json="[]"
    if [[ ${#updated_users[@]} -gt 0 ]]; then
        local joined=""
        for item in "${updated_users[@]}"; do
            if [[ -z "$joined" ]]; then joined="$item"; else joined="${joined}, $item"; fi
        done
        updated_json="[${joined}]"
    fi

    local deactivated_json="[]"
    if [[ ${#deactivated_users[@]} -gt 0 ]]; then
        local joined=""
        for item in "${deactivated_users[@]}"; do
            if [[ -z "$joined" ]]; then joined="$item"; else joined="${joined}, $item"; fi
        done
        deactivated_json="[${joined}]"
    fi

    local errors_json="[]"
    if [[ ${#errors[@]} -gt 0 ]]; then
        local joined=""
        for item in "${errors[@]}"; do
            if [[ -z "$joined" ]]; then joined="\"$item\""; else joined="${joined}, \"$item\""; fi
        done
        errors_json="[${joined}]"
    fi

    local json_report
    json_report=$(cat <<EOF
{
  "timestamp": "${run_timestamp}",
  "manifest": "${MANIFEST_PATH}",
  "dry_run": ${DRY_RUN},
  "summary": {
    "created": ${#created_users[@]},
    "updated": ${#updated_users[@]},
    "deactivated": ${#deactivated_users[@]},
    "errors": ${#errors[@]}
  },
  "created_users": ${created_json},
  "updated_users": ${updated_json},
  "deactivated_users": ${deactivated_json},
  "errors": ${errors_json}
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
        echo "  User and Group Provisioning Summary"
        echo "=================================================="
        echo "Manifest     : ${MANIFEST_PATH}"
        echo "Dry Run      : ${DRY_RUN}"
        echo "Created      : ${#created_users[@]}"
        echo "Updated      : ${#updated_users[@]}"
        echo "Deactivated  : ${#deactivated_users[@]}"
        echo "Errors       : ${#errors[@]}"
        echo "=================================================="
        if [[ ${#created_users[@]} -gt 0 ]]; then
            echo "Created Users:"
            for u in "${created_users[@]}"; do echo "  - $u"; done
        fi
        if [[ ${#updated_users[@]} -gt 0 ]]; then
            echo "Updated Users:"
            for u in "${updated_users[@]}"; do echo "  - $u"; done
        fi
        if [[ ${#deactivated_users[@]} -gt 0 ]]; then
            echo "Deactivated Users:"
            for u in "${deactivated_users[@]}"; do echo "  - $u"; done
        fi
        if [[ ${#errors[@]} -gt 0 ]]; then
            echo "Errors:"
            for e in "${errors[@]}"; do echo "  - $e"; done
        fi
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
