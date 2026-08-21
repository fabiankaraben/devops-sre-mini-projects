#!/usr/bin/env bash
# ==============================================================================
# Script Name: log_rotate.sh
# Description: Production-grade Log Rotation & Archiver Utility.
#              Safely rotates active log files without interrupting running
#              services using 'copytruncate' or signal-based methods.
#              Compresses rotated files with gzip, applies ISO-8601 timestamps,
#              enforces retention policies, and outputs JSON metrics.
#
# Exit Codes:
#   0 - Success: Logs checked/rotated successfully.
#   1 - Warning: Partial rotation failure or non-critical issue.
#   2 - Error: Critical execution error, invalid argument, or missing directory.
# ==============================================================================

set -euo pipefail

readonly VERSION="1.0.0"

# Defaults
LOG_DIR="./logs"
ARCHIVE_DIR="./archive"
PATTERN="*.log"
MAX_SIZE_BYTES=0          # 0 = do not filter by size unless specified
MAX_AGE_SECONDS=0         # 0 = do not filter by age unless specified
RETENTION_DAYS=0          # 0 = no age-based retention pruning
RETENTION_COUNT=0         # 0 = no count-based retention pruning
COMPRESS=true
ROTATION_METHOD="copytruncate"
TARGET_PID=""
REOPEN_SIGNAL="USR1"
DRY_RUN=false
JSON_OUTPUT=false
PRETTY_PRINT=false

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Log File Rotation and Archiver (DevOps / SRE Mini-Project)
Rotates, compresses (gzip), timestamps, and archives active log files.

Options:
  --log-dir <path>          Directory containing active logs to rotate (default: ./logs)
  --archive-dir <path>      Destination directory for compressed archives (default: ./archive)
  --pattern <glob>          File matching glob pattern (default: *.log)
  
  --max-size <size>         Rotate if file size exceeds threshold (e.g. 500K, 10M, 1G, 1048576)
  --max-age-days <days>     Rotate files modified more than N days ago
  --max-age-mins <mins>     Rotate files modified more than N minutes ago (useful for testing)
  
  --retention-days <days>   Purge archive files older than N days from archive directory
  --retention-count <count> Keep only the most recent N archives per log file pattern
  
  --no-compress             Skip gzip compression (keep uncompressed archives)
  --method <method>         Rotation strategy: 'copytruncate' (default) or 'signal'
  --pid <pid>               Target daemon PID to signal (required when method is 'signal')
  --signal <signal>         Signal to send daemon after renaming (default: USR1, e.g. HUP)
  
  --dry-run                 Simulate rotations and show actions without modifying files
  --json                    Output rotation summary in JSON format
  --pretty                  Format JSON output with indentation (when combined with --json)
  -h, --help                Display this help message and exit
  -v, --version             Display script version and exit

Examples:
  # Rotate logs in ./logs larger than 5MB to ./archive with gzip
  $(basename "$0") --log-dir ./logs --archive-dir ./archive --max-size 5M

  # Rotate logs older than 7 days and retain last 10 archives with JSON summary
  $(basename "$0") --max-age-days 7 --retention-count 10 --json --pretty

  # Preview actions without modifying any files
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

# Convert human size strings (e.g. 500K, 10M, 2G) to raw bytes
parse_size_to_bytes() {
    local str="$1"
    str=$(echo "$str" | tr '[:lower:]' '[:upper:]')
    
    if [[ "$str" =~ ^([0-9]+)K(B)?$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 1024 ))
    elif [[ "$str" =~ ^([0-9]+)M(B)?$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 1024 * 1024 ))
    elif [[ "$str" =~ ^([0-9]+)G(B)?$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 1024 * 1024 * 1024 ))
    elif [[ "$str" =~ ^[0-9]+$ ]]; then
        echo "$str"
    else
        print_error "Invalid size format: '${str}'. Use units like 500K, 10M, 1G or raw bytes."
        exit 2
    fi
}

# Portable file size in bytes (works across GNU coreutils & BSD/macOS)
get_file_size_bytes() {
    local file="$1"
    if stat -c %s "$file" >/dev/null 2>&1; then
        stat -c %s "$file"
    elif stat -f %z "$file" >/dev/null 2>&1; then
        stat -f %z "$file"
    else
        wc -c < "$file" | tr -d ' '
    fi
}

# Portable file modification epoch timestamp
get_file_mtime_epoch() {
    local file="$1"
    if stat -c %Y "$file" >/dev/null 2>&1; then
        stat -c %Y "$file"
    elif stat -f %m "$file" >/dev/null 2>&1; then
        stat -f %m "$file"
    else
        date +%s
    fi
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)
                [[ $# -lt 2 ]] && { print_error "Missing value for --log-dir"; exit 2; }
                LOG_DIR="$2"
                shift 2
                ;;
            --archive-dir)
                [[ $# -lt 2 ]] && { print_error "Missing value for --archive-dir"; exit 2; }
                ARCHIVE_DIR="$2"
                shift 2
                ;;
            --pattern)
                [[ $# -lt 2 ]] && { print_error "Missing value for --pattern"; exit 2; }
                PATTERN="$2"
                shift 2
                ;;
            --max-size)
                [[ $# -lt 2 ]] && { print_error "Missing value for --max-size"; exit 2; }
                MAX_SIZE_BYTES=$(parse_size_to_bytes "$2")
                shift 2
                ;;
            --max-age-days)
                [[ $# -lt 2 ]] && { print_error "Missing value for --max-age-days"; exit 2; }
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then print_error "--max-age-days must be a positive integer"; exit 2; fi
                MAX_AGE_SECONDS=$(( $2 * 86400 ))
                shift 2
                ;;
            --max-age-mins)
                [[ $# -lt 2 ]] && { print_error "Missing value for --max-age-mins"; exit 2; }
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then print_error "--max-age-mins must be a positive integer"; exit 2; fi
                MAX_AGE_SECONDS=$(( $2 * 60 ))
                shift 2
                ;;
            --retention-days)
                [[ $# -lt 2 ]] && { print_error "Missing value for --retention-days"; exit 2; }
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then print_error "--retention-days must be a positive integer"; exit 2; fi
                RETENTION_DAYS="$2"
                shift 2
                ;;
            --retention-count)
                [[ $# -lt 2 ]] && { print_error "Missing value for --retention-count"; exit 2; }
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then print_error "--retention-count must be a positive integer"; exit 2; fi
                RETENTION_COUNT="$2"
                shift 2
                ;;
            --no-compress)
                COMPRESS=false
                shift
                ;;
            --method)
                [[ $# -lt 2 ]] && { print_error "Missing value for --method"; exit 2; }
                if [[ "$2" != "copytruncate" && "$2" != "signal" ]]; then
                    print_error "--method must be either 'copytruncate' or 'signal'"
                    exit 2
                fi
                ROTATION_METHOD="$2"
                shift 2
                ;;
            --pid)
                [[ $# -lt 2 ]] && { print_error "Missing value for --pid"; exit 2; }
                TARGET_PID="$2"
                shift 2
                ;;
            --signal)
                [[ $# -lt 2 ]] && { print_error "Missing value for --signal"; exit 2; }
                REOPEN_SIGNAL="$2"
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
                echo "log_rotate.sh version ${VERSION}"
                exit 0
                ;;
            *)
                print_error "Unrecognized option: '$1'. Use --help for usage information."
                exit 2
                ;;
        esac
    done

    if [[ "$ROTATION_METHOD" == "signal" && -z "$TARGET_PID" ]]; then
        print_error "--pid is required when --method is set to 'signal'"
        exit 2
    fi
}

# ------------------------------------------------------------------------------
# Rotation & Archiving Logic
# ------------------------------------------------------------------------------

main() {
    parse_args "$@"

    local run_timestamp
    run_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local iso_file_stamp
    # Safe ISO-8601 formatted string for file naming: YYYY-MM-DDTHH-MM-SSZ
    iso_file_stamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
    local current_epoch
    current_epoch=$(date +%s)

    if [[ ! -d "$LOG_DIR" ]]; then
        print_error "Log directory '${LOG_DIR}' does not exist"
        exit 2
    fi

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$ARCHIVE_DIR"
    fi

    local rotated_entries=()
    local pruned_entries=()
    local total_original_bytes=0
    local total_compressed_bytes=0

    # Discover candidate log files matching pattern
    # Using nullglob so unmatched patterns expand to empty array
    shopt -s nullglob
    local log_files=("$LOG_DIR"/$PATTERN)
    shopt -u nullglob

    for log_file in "${log_files[@]}"; do
        [[ -f "$log_file" ]] || continue

        local file_size
        file_size=$(get_file_size_bytes "$log_file")
        local file_mtime
        file_mtime=$(get_file_mtime_epoch "$log_file")
        local file_age=$(( current_epoch - file_mtime ))

        # Check conditions for rotation
        local should_rotate=false

        if [[ $MAX_SIZE_BYTES -gt 0 && $MAX_AGE_SECONDS -gt 0 ]]; then
            # Both specified: rotate if either condition is met
            if [[ $file_size -ge $MAX_SIZE_BYTES || $file_age -ge $MAX_AGE_SECONDS ]]; then
                should_rotate=true
            fi
        elif [[ $MAX_SIZE_BYTES -gt 0 ]]; then
            if [[ $file_size -ge $MAX_SIZE_BYTES ]]; then
                should_rotate=true
            fi
        elif [[ $MAX_AGE_SECONDS -gt 0 ]]; then
            if [[ $file_age -ge $MAX_AGE_SECONDS ]]; then
                should_rotate=true
            fi
        else
            # No size or age specified: rotate if file is non-empty
            if [[ $file_size -gt 0 ]]; then
                should_rotate=true
            fi
        fi

        if [[ "$should_rotate" == true ]]; then
            local base_name
            base_name=$(basename "$log_file")
            local name_without_ext="${base_name%.*}"
            local ext="${base_name##*.}"
            if [[ "$name_without_ext" == "$ext" ]]; then
                ext="log"
            fi

            local archive_base="${name_without_ext}_${iso_file_stamp}.${ext}"
            local final_archive="${ARCHIVE_DIR}/${archive_base}"
            if [[ "$COMPRESS" == true ]]; then
                final_archive="${final_archive}.gz"
            fi

            if [[ "$DRY_RUN" == true ]]; then
                rotated_entries+=("{\"file\": \"${log_file}\", \"archive\": \"${final_archive}\", \"size_bytes\": ${file_size}, \"action\": \"dry-run-rotate\"}")
                total_original_bytes=$(( total_original_bytes + file_size ))
            else
                local temp_copy="/tmp/rotate_${base_name}_$$"

                if [[ "$ROTATION_METHOD" == "copytruncate" ]]; then
                    # Step 1: Copy active log preserving attributes
                    cp -p "$log_file" "$temp_copy"
                    # Step 2: Atomic in-place truncation
                    : > "$log_file"
                elif [[ "$ROTATION_METHOD" == "signal" ]]; then
                    # Step 1: Rename active log
                    mv "$log_file" "$temp_copy"
                    # Step 2: Signal process to reopen file descriptor
                    if kill -0 "$TARGET_PID" 2>/dev/null; then
                        kill -s "$REOPEN_SIGNAL" "$TARGET_PID" 2>/dev/null || true
                    fi
                    sleep 0.1
                fi

                # Step 3: Compress or move into archive destination
                local final_size=0
                if [[ "$COMPRESS" == true ]]; then
                    gzip -c "$temp_copy" > "$final_archive"
                    rm -f "$temp_copy"
                    final_size=$(get_file_size_bytes "$final_archive")
                else
                    mv "$temp_copy" "$final_archive"
                    final_size=$(get_file_size_bytes "$final_archive")
                fi

                total_original_bytes=$(( total_original_bytes + file_size ))
                total_compressed_bytes=$(( total_compressed_bytes + final_size ))

                rotated_entries+=("{\"file\": \"${log_file}\", \"archive\": \"${final_archive}\", \"original_bytes\": ${file_size}, \"compressed_bytes\": ${final_size}}")
            fi
        fi
    done

    # --------------------------------------------------------------------------
    # Retention Policy Enforcement (Pruning old archives)
    # --------------------------------------------------------------------------
    if [[ -d "$ARCHIVE_DIR" ]]; then
        # 1. Retention by Age (days)
        if [[ $RETENTION_DAYS -gt 0 ]]; then
            local retention_cutoff_seconds=$(( RETENTION_DAYS * 86400 ))
            shopt -s nullglob
            local existing_archives=("$ARCHIVE_DIR"/*)
            shopt -u nullglob

            for arch in "${existing_archives[@]}"; do
                [[ -f "$arch" ]] || continue
                local arch_mtime
                arch_mtime=$(get_file_mtime_epoch "$arch")
                local arch_age=$(( current_epoch - arch_mtime ))

                if [[ $arch_age -ge $retention_cutoff_seconds ]]; then
                    if [[ "$DRY_RUN" == true ]]; then
                        pruned_entries+=("{\"file\": \"${arch}\", \"action\": \"dry-run-prune-age\"}")
                    else
                        rm -f "$arch"
                        pruned_entries+=("{\"file\": \"${arch}\", \"action\": \"pruned-age\"}")
                    fi
                fi
            done
        fi

        # 2. Retention by Count (keep latest N archives)
        if [[ $RETENTION_COUNT -gt 0 ]]; then
            # Find all archives sorted by modification time (newest first)
            shopt -s nullglob
            local all_archives=("$ARCHIVE_DIR"/*)
            shopt -u nullglob

            if [[ ${#all_archives[@]} -gt $RETENTION_COUNT ]]; then
                # Sort files by mtime descending (most recent first)
                local sorted_archives=()
                while IFS= read -r file; do
                    sorted_archives+=("$file")
                done < <(
                    for f in "${all_archives[@]}"; do
                        [[ -f "$f" ]] && printf "%s\t%s\n" "$(get_file_mtime_epoch "$f")" "$f"
                    done | sort -rn | cut -f2-
                )

                local count=0
                for arch in "${sorted_archives[@]}"; do
                    count=$(( count + 1 ))
                    if [[ $count -gt $RETENTION_COUNT ]]; then
                        if [[ "$DRY_RUN" == true ]]; then
                            pruned_entries+=("{\"file\": \"${arch}\", \"action\": \"dry-run-prune-count\"}")
                        else
                            rm -f "$arch"
                            pruned_entries+=("{\"file\": \"${arch}\", \"action\": \"pruned-count\"}")
                        fi
                    fi
                done
            fi
        fi
    fi

    # --------------------------------------------------------------------------
    # Assemble & Print Report
    # --------------------------------------------------------------------------
    local bytes_saved=$(( total_original_bytes - total_compressed_bytes ))
    if [[ $bytes_saved -lt 0 ]]; then bytes_saved=0; fi

    local rotated_json="[]"
    if [[ ${#rotated_entries[@]} -gt 0 ]]; then
        local joined=""
        for item in "${rotated_entries[@]}"; do
            if [[ -z "$joined" ]]; then joined="$item"; else joined="${joined}, $item"; fi
        done
        rotated_json="[${joined}]"
    fi

    local pruned_json="[]"
    if [[ ${#pruned_entries[@]} -gt 0 ]]; then
        local joined=""
        for item in "${pruned_entries[@]}"; do
            if [[ -z "$joined" ]]; then joined="$item"; else joined="${joined}, $item"; fi
        done
        pruned_json="[${joined}]"
    fi

    local json_report
    json_report=$(cat <<EOF
{
  "timestamp": "${run_timestamp}",
  "log_dir": "${LOG_DIR}",
  "archive_dir": "${ARCHIVE_DIR}",
  "method": "${ROTATION_METHOD}",
  "compressed": ${COMPRESS},
  "dry_run": ${DRY_RUN},
  "summary": {
    "files_rotated": ${#rotated_entries[@]},
    "archives_pruned": ${#pruned_entries[@]},
    "total_original_bytes": ${total_original_bytes},
    "total_compressed_bytes": ${total_compressed_bytes},
    "bytes_saved": ${bytes_saved}
  },
  "rotated_files": ${rotated_json},
  "pruned_archives": ${pruned_json}
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
        echo "  Log Rotation & Archiver Summary"
        echo "=================================================="
        echo "Timestamp       : ${run_timestamp}"
        echo "Log Directory   : ${LOG_DIR}"
        echo "Archive Dir     : ${ARCHIVE_DIR}"
        echo "Method          : ${ROTATION_METHOD}"
        echo "Compressed      : ${COMPRESS}"
        echo "Dry Run         : ${DRY_RUN}"
        echo "Files Rotated   : ${#rotated_entries[@]}"
        echo "Archives Pruned : ${#pruned_entries[@]}"
        echo "Bytes Saved     : ${bytes_saved} bytes"
        echo "=================================================="
        if [[ ${#rotated_entries[@]} -gt 0 ]]; then
            echo "Rotated Archives:"
            for r in "${rotated_entries[@]}"; do
                echo "  - $r"
            done
        fi
        if [[ ${#pruned_entries[@]} -gt 0 ]]; then
            echo "Pruned Archives:"
            for p in "${pruned_entries[@]}"; do
                echo "  - $p"
            done
        fi
    fi

    exit 0
}

main "$@"
