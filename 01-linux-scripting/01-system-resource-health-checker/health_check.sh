#!/usr/bin/env bash
# ==============================================================================
# Script Name: health_check.sh
# Description: Production-grade Linux System Resource Health Checker.
#              Inspects CPU (/proc/stat), Memory (/proc/meminfo), and Disk (df),
#              evaluates configured thresholds, and outputs formatted JSON
#              with standard SRE exit codes.
#
# Exit Codes:
#   0 - OK       : All metrics within normal parameters.
#   1 - WARNING  : At least one metric exceeded warning threshold.
#   2 - CRITICAL : At least one metric exceeded critical threshold.
#   3 - UNKNOWN  : Execution error, invalid arguments, or missing dependencies.
# ==============================================================================

set -euo pipefail

# Script version
readonly VERSION="1.0.0"

# Default Thresholds (Percentages)
CPU_WARN_DEFAULT=80.0
CPU_CRIT_DEFAULT=95.0
MEM_WARN_DEFAULT=80.0
MEM_CRIT_DEFAULT=95.0
DISK_WARN_DEFAULT=85.0
DISK_CRIT_DEFAULT=95.0

# User-configurable parameters
CPU_WARN="${CPU_WARN_DEFAULT}"
CPU_CRIT="${CPU_CRIT_DEFAULT}"
MEM_WARN="${MEM_WARN_DEFAULT}"
MEM_CRIT="${MEM_CRIT_DEFAULT}"
DISK_WARN="${DISK_WARN_DEFAULT}"
DISK_CRIT="${DISK_CRIT_DEFAULT}"
DISK_PATH="/"
SAMPLE_INTERVAL=1
PRETTY_PRINT=false

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

System Resource Health Checker (DevOps / SRE Mini-Project)
Inspects system health metrics and emits structured JSON status.

Options:
  --cpu-max <percent>       Alias for warning threshold for CPU (default: ${CPU_WARN_DEFAULT}%)
  --cpu-warn <percent>      Warning threshold percentage for CPU (default: ${CPU_WARN_DEFAULT}%)
  --cpu-crit <percent>      Critical threshold percentage for CPU (default: ${CPU_CRIT_DEFAULT}%)
  
  --mem-max <percent>       Alias for warning threshold for Memory (default: ${MEM_WARN_DEFAULT}%)
  --mem-warn <percent>      Warning threshold percentage for Memory (default: ${MEM_WARN_DEFAULT}%)
  --mem-crit <percent>      Critical threshold percentage for Memory (default: ${MEM_CRIT_DEFAULT}%)
  
  --disk-max <percent>      Alias for warning threshold for Disk (default: ${DISK_WARN_DEFAULT}%)
  --disk-warn <percent>     Warning threshold percentage for Disk (default: ${DISK_WARN_DEFAULT}%)
  --disk-crit <percent>     Critical threshold percentage for Disk (default: ${DISK_CRIT_DEFAULT}%)
  
  --disk-path <path>        Filesystem mount point or path to check (default: /)
  --sample-interval <sec>   Sampling window in seconds for CPU delta (default: 1)
  --pretty                  Format JSON output with 2-space indentation
  -h, --help                Display this help message and exit
  -v, --version             Display version information and exit

Exit Codes:
  0 = OK       (All metrics are within acceptable thresholds)
  1 = WARNING  (One or more metrics exceeded warning thresholds)
  2 = CRITICAL (One or more metrics exceeded critical thresholds)
  3 = UNKNOWN  (Invalid CLI arguments, system errors, or missing requirements)

Example:
  $(basename "$0") --cpu-max 50 --mem-max 75 --pretty
EOF
}

print_error() {
    local msg="$1"
    echo "{\"error\": \"${msg}\", \"status\": \"UNKNOWN\", \"exit_code\": 3}" >&2
}

is_numeric() {
    local val="$1"
    if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_percentage() {
    local name="$1"
    local val="$2"
    if ! is_numeric "$val"; then
        print_error "Invalid numeric value for ${name}: '${val}'"
        exit 3
    fi
    # Check range 0.0 to 100.0 using awk
    local in_range
    in_range=$(awk -v v="$val" 'BEGIN { if (v >= 0.0 && v <= 100.0) print "1"; else print "0" }')
    if [[ "$in_range" -ne 1 ]]; then
        print_error "Value for ${name} must be between 0.0 and 100.0 (got: ${val})"
        exit 3
    fi
}

# ------------------------------------------------------------------------------
# CLI Argument Parsing
# ------------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpu-max)
                [[ $# -lt 2 ]] && { print_error "Missing value for --cpu-max"; exit 3; }
                CPU_WARN="$2"
                shift 2
                ;;
            --cpu-warn)
                [[ $# -lt 2 ]] && { print_error "Missing value for --cpu-warn"; exit 3; }
                CPU_WARN="$2"
                shift 2
                ;;
            --cpu-crit)
                [[ $# -lt 2 ]] && { print_error "Missing value for --cpu-crit"; exit 3; }
                CPU_CRIT="$2"
                shift 2
                ;;
            --mem-max)
                [[ $# -lt 2 ]] && { print_error "Missing value for --mem-max"; exit 3; }
                MEM_WARN="$2"
                shift 2
                ;;
            --mem-warn)
                [[ $# -lt 2 ]] && { print_error "Missing value for --mem-warn"; exit 3; }
                MEM_WARN="$2"
                shift 2
                ;;
            --mem-crit)
                [[ $# -lt 2 ]] && { print_error "Missing value for --mem-crit"; exit 3; }
                MEM_CRIT="$2"
                shift 2
                ;;
            --disk-max)
                [[ $# -lt 2 ]] && { print_error "Missing value for --disk-max"; exit 3; }
                DISK_WARN="$2"
                shift 2
                ;;
            --disk-warn)
                [[ $# -lt 2 ]] && { print_error "Missing value for --disk-warn"; exit 3; }
                DISK_WARN="$2"
                shift 2
                ;;
            --disk-crit)
                [[ $# -lt 2 ]] && { print_error "Missing value for --disk-crit"; exit 3; }
                DISK_CRIT="$2"
                shift 2
                ;;
            --disk-path)
                [[ $# -lt 2 ]] && { print_error "Missing value for --disk-path"; exit 3; }
                DISK_PATH="$2"
                shift 2
                ;;
            --sample-interval)
                [[ $# -lt 2 ]] && { print_error "Missing value for --sample-interval"; exit 3; }
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            --pretty)
                PRETTY_PRINT=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            -v|--version)
                echo "health_check.sh version ${VERSION}"
                exit 0
                ;;
            *)
                print_error "Unrecognized argument: '$1'. Use --help for usage information."
                exit 3
                ;;
        esac
    done

    # Validate numeric threshold inputs
    validate_percentage "--cpu-warn/--cpu-max" "$CPU_WARN"
    validate_percentage "--cpu-crit" "$CPU_CRIT"
    validate_percentage "--mem-warn/--mem-max" "$MEM_WARN"
    validate_percentage "--mem-crit" "$MEM_CRIT"
    validate_percentage "--disk-warn/--disk-max" "$DISK_WARN"
    validate_percentage "--disk-crit" "$DISK_CRIT"

    if ! is_numeric "$SAMPLE_INTERVAL" || [[ $(awk -v v="$SAMPLE_INTERVAL" 'BEGIN { print (v > 0) ? "1" : "0" }') -ne 1 ]]; then
        print_error "--sample-interval must be a positive number greater than 0"
        exit 3
    fi

    if [[ ! -e "$DISK_PATH" ]]; then
        print_error "Disk path '${DISK_PATH}' does not exist"
        exit 3
    fi
}

# ------------------------------------------------------------------------------
# System Metric Extractors
# ------------------------------------------------------------------------------

# Function: get_cpu_cores
# Determines total online CPU cores
get_cpu_cores() {
    if [[ -r /proc/cpuinfo ]]; then
        grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
    elif command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu 2>/dev/null || echo 1
    else
        echo 1
    fi
}

# Function: read_proc_stat_cpu
# Extracts user, nice, system, idle, iowait, irq, softirq, steal from /proc/stat
read_proc_stat_cpu() {
    awk '/^cpu / {
        idle = $5 + $6; # idle + iowait
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9; # user+nice+system+idle+iowait+irq+softirq+steal
        print idle, total
    }' /proc/stat
}

# Function: get_cpu_usage
# Measures instantaneous CPU percentage over the configured sample window
get_cpu_usage() {
    if [[ -r /proc/stat ]]; then
        local snap1 snap2
        snap1=$(read_proc_stat_cpu)
        sleep "${SAMPLE_INTERVAL}"
        snap2=$(read_proc_stat_cpu)

        local idle1 total1 idle2 total2
        read -r idle1 total1 <<< "$snap1"
        read -r idle2 total2 <<< "$snap2"

        awk -v i1="$idle1" -v t1="$total1" -v i2="$idle2" -v t2="$total2" 'BEGIN {
            idle_delta = i2 - i1;
            total_delta = t2 - t1;
            if (total_delta <= 0) {
                printf "0.0";
            } else {
                usage = (1.0 - (idle_delta / total_delta)) * 100.0;
                if (usage < 0.0) usage = 0.0;
                if (usage > 100.0) usage = 100.0;
                printf "%.1f", usage;
            }
        }'
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS fallback using top
        local cpu_idle
        cpu_idle=$(top -l 1 -n 0 | awk '/CPU usage:/ { gsub("%", "", $7); print $7 }')
        if is_numeric "$cpu_idle"; then
            awk -v idle="$cpu_idle" 'BEGIN { printf "%.1f", 100.0 - idle }'
        else
            echo "0.0"
        fi
    else
        # Generic fallback
        echo "0.0"
    fi
}

# Function: get_memory_metrics
# Reads /proc/meminfo and calculates total, used, available in MB and percentage
get_memory_metrics() {
    if [[ -r /proc/meminfo ]]; then
        awk '
            /^MemTotal:/ { total = $2 }
            /^MemFree:/ { free = $2 }
            /^MemAvailable:/ { avail = $2 }
            /^Buffers:/ { buffers = $2 }
            /^Cached:/ { cached = $2 }
            END {
                # If MemAvailable is absent (older Linux kernels), estimate it
                if (avail == 0) {
                    avail = free + buffers + cached
                }
                used = total - avail
                if (used < 0) used = 0
                usage_pct = (total > 0) ? (used / total) * 100.0 : 0.0
                
                total_mb = int(total / 1024)
                used_mb = int(used / 1024)
                avail_mb = int(avail / 1024)
                
                printf "%d %d %d %.1f", total_mb, used_mb, avail_mb, usage_pct
            }
        ' /proc/meminfo
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS fallback using sysctl and vm_stat
        local total_bytes total_mb used_mb avail_mb usage_pct
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        total_mb=$(( total_bytes / 1024 / 1024 ))
        
        # Approximate memory using vm_stat
        local page_size free_pages active_pages inactive_pages wired_pages
        page_size=$(vm_stat | awk '/page size of/ { print $8 }' 2>/dev/null || echo 4096)
        free_pages=$(vm_stat | awk '/Pages free:/ { gsub("\\.", "", $3); print $3 }' 2>/dev/null || echo 0)
        active_pages=$(vm_stat | awk '/Pages active:/ { gsub("\\.", "", $3); print $3 }' 2>/dev/null || echo 0)
        inactive_pages=$(vm_stat | awk '/Pages inactive:/ { gsub("\\.", "", $3); print $3 }' 2>/dev/null || echo 0)
        wired_pages=$(vm_stat | awk '/Pages wired down:/ { gsub("\\.", "", $4); print $4 }' 2>/dev/null || echo 0)
        
        local used_bytes avail_bytes
        used_bytes=$(( (active_pages + wired_pages) * page_size ))
        avail_bytes=$(( (free_pages + inactive_pages) * page_size ))
        used_mb=$(( used_bytes / 1024 / 1024 ))
        avail_mb=$(( avail_bytes / 1024 / 1024 ))
        
        if [[ $total_mb -gt 0 ]]; then
            usage_pct=$(awk -v u="$used_mb" -v t="$total_mb" 'BEGIN { printf "%.1f", (u / t) * 100.0 }')
        else
            total_mb=1024
            used_mb=512
            avail_mb=512
            usage_pct="50.0"
        fi
        printf "%d %d %d %s" "$total_mb" "$used_mb" "$avail_mb" "$usage_pct"
    else
        printf "1024 512 512 50.0"
    fi
}

# Function: get_disk_metrics
# Inspects target filesystem mount point using POSIX df -Pk
get_disk_metrics() {
    local target_path="$1"
    
    # Run df with POSIX standard formatting (-P) in 1024-byte blocks (-k)
    local df_output
    df_output=$(df -Pk "$target_path" 2>/dev/null | tail -n 1)
    
    if [[ -z "$df_output" ]]; then
        print_error "Failed to retrieve disk statistics for '${target_path}'"
        exit 3
    fi

    # Format: Filesystem 1024-blocks Used Available Capacity Mounted_on
    awk -v target="$target_path" '{
        total_kb = $2
        used_kb = $3
        avail_kb = $4
        capacity_str = $5
        mount_point = $6
        
        # Remove % sign from capacity
        gsub("%", "", capacity_str)
        usage_pct = capacity_str + 0.0
        
        total_gb = total_kb / (1024 * 1024)
        used_gb = used_kb / (1024 * 1024)
        avail_gb = avail_kb / (1024 * 1024)
        
        printf "%s %.2f %.2f %.2f %.1f", mount_point, total_gb, used_gb, avail_gb, usage_pct
    }' <<< "$df_output"
}

# Function: evaluate_metric_status
# Determines OK / WARNING / CRITICAL status based on metric vs thresholds
evaluate_metric_status() {
    local val="$1"
    local warn="$2"
    local crit="$3"

    awk -v v="$val" -v w="$warn" -v c="$crit" 'BEGIN {
        if (v >= c) {
            print "CRITICAL"
        } else if (v >= w) {
            print "WARNING"
        } else {
            print "OK"
        }
    }'
}

# ------------------------------------------------------------------------------
# Main Execution Logic
# ------------------------------------------------------------------------------

main() {
    parse_args "$@"

    local hostname timestamp
    hostname=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown-host")
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Collect CPU Metrics
    local cpu_cores cpu_usage
    cpu_cores=$(get_cpu_cores)
    cpu_usage=$(get_cpu_usage)
    local cpu_status
    cpu_status=$(evaluate_metric_status "$cpu_usage" "$CPU_WARN" "$CPU_CRIT")

    # Collect Memory Metrics
    local mem_raw mem_total_mb mem_used_mb mem_avail_mb mem_usage_pct
    mem_raw=$(get_memory_metrics)
    read -r mem_total_mb mem_used_mb mem_avail_mb mem_usage_pct <<< "$mem_raw"
    local mem_status
    mem_status=$(evaluate_metric_status "$mem_usage_pct" "$MEM_WARN" "$MEM_CRIT")

    # Collect Disk Metrics
    local disk_raw disk_mount disk_total_gb disk_used_gb disk_avail_gb disk_usage_pct
    disk_raw=$(get_disk_metrics "$DISK_PATH")
    read -r disk_mount disk_total_gb disk_used_gb disk_avail_gb disk_usage_pct <<< "$disk_raw"
    local disk_status
    disk_status=$(evaluate_metric_status "$disk_usage_pct" "$DISK_WARN" "$DISK_CRIT")

    # Determine Overall System Status and Exit Code
    local overall_status="OK"
    local exit_code=0
    local alerts=()

    if [[ "$cpu_status" == "CRITICAL" || "$mem_status" == "CRITICAL" || "$disk_status" == "CRITICAL" ]]; then
        overall_status="CRITICAL"
        exit_code=2
    elif [[ "$cpu_status" == "WARNING" || "$mem_status" == "WARNING" || "$disk_status" == "WARNING" ]]; then
        overall_status="WARNING"
        exit_code=1
    fi

    # Compile Alert Messages (using tr for portable lowercase conversion)
    if [[ "$cpu_status" == "CRITICAL" ]]; then
        alerts+=("CPU usage (${cpu_usage}%) exceeds critical threshold (${CPU_CRIT}%)")
    elif [[ "$cpu_status" == "WARNING" ]]; then
        alerts+=("CPU usage (${cpu_usage}%) exceeds warning threshold (${CPU_WARN}%)")
    fi

    if [[ "$mem_status" == "CRITICAL" ]]; then
        alerts+=("Memory usage (${mem_usage_pct}%) exceeds critical threshold (${MEM_CRIT}%)")
    elif [[ "$mem_status" == "WARNING" ]]; then
        alerts+=("Memory usage (${mem_usage_pct}%) exceeds warning threshold (${MEM_WARN}%)")
    fi

    if [[ "$disk_status" == "CRITICAL" ]]; then
        alerts+=("Disk usage on '${disk_mount}' (${disk_usage_pct}%) exceeds critical threshold (${DISK_CRIT}%)")
    elif [[ "$disk_status" == "WARNING" ]]; then
        alerts+=("Disk usage on '${disk_mount}' (${disk_usage_pct}%) exceeds warning threshold (${DISK_WARN}%)")
    fi

    # Build Alerts JSON array
    local alerts_json="[]"
    if [[ ${#alerts[@]} -gt 0 ]]; then
        local formatted_alerts=""
        for alert in "${alerts[@]}"; do
            if [[ -z "$formatted_alerts" ]]; then
                formatted_alerts="\"${alert}\""
            else
                formatted_alerts="${formatted_alerts}, \"${alert}\""
            fi
        done
        alerts_json="[${formatted_alerts}]"
    fi

    # Assemble JSON Payload
    local json_output
    json_output=$(cat <<EOF
{
  "timestamp": "${timestamp}",
  "hostname": "${hostname}",
  "status": "${overall_status}",
  "exit_code": ${exit_code},
  "thresholds": {
    "cpu": {
      "warning_percent": ${CPU_WARN},
      "critical_percent": ${CPU_CRIT}
    },
    "memory": {
      "warning_percent": ${MEM_WARN},
      "critical_percent": ${MEM_CRIT}
    },
    "disk": {
      "mount_point": "${DISK_PATH}",
      "warning_percent": ${DISK_WARN},
      "critical_percent": ${DISK_CRIT}
    }
  },
  "metrics": {
    "cpu": {
      "usage_percent": ${cpu_usage},
      "cores": ${cpu_cores},
      "status": "${cpu_status}"
    },
    "memory": {
      "total_mb": ${mem_total_mb},
      "used_mb": ${mem_used_mb},
      "available_mb": ${mem_avail_mb},
      "usage_percent": ${mem_usage_pct},
      "status": "${mem_status}"
    },
    "disk": {
      "mount_point": "${disk_mount}",
      "total_gb": ${disk_total_gb},
      "used_gb": ${disk_used_gb},
      "available_gb": ${disk_avail_gb},
      "usage_percent": ${disk_usage_pct},
      "status": "${disk_status}"
    }
  },
  "alerts": ${alerts_json}
}
EOF
)

    if [[ "$PRETTY_PRINT" == true ]] && command -v jq >/dev/null 2>&1; then
        echo "$json_output" | jq .
    else
        echo "$json_output"
    fi

    exit "$exit_code"
}

main "$@"
