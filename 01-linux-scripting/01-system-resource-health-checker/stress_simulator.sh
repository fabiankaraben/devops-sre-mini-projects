#!/usr/bin/env bash
# ==============================================================================
# Script Name: stress_simulator.sh
# Description: Workload & Failure Injection Simulator for Linux Systems.
#              Safely generates controllable spikes in CPU (spin-loops),
#              Memory (ramfs/tmpfs allocation), and Disk I/O (dd dummy files).
#              Features automated cleanup via signal traps to prevent leaks.
# ==============================================================================

set -euo pipefail

# Default stress parameters
DEFAULT_DURATION=10
DEFAULT_CPU_WORKERS=2
DEFAULT_MEM_MB=256
DEFAULT_DISK_MB=500
STRESS_DIR="/tmp/health_check_stress_$$"

# State flags
STRESS_CPU=false
STRESS_MEM=false
STRESS_DISK=false
DURATION="${DEFAULT_DURATION}"
CPU_WORKERS="${DEFAULT_CPU_WORKERS}"
MEM_MB="${DEFAULT_MEM_MB}"
DISK_MB="${DEFAULT_DISK_MB}"

# Tracking background worker PIDs
WORKER_PIDS=()
CLEANUP_DONE=false

# ------------------------------------------------------------------------------
# Usage & Help
# ------------------------------------------------------------------------------

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Workload & Failure Simulator (DevOps / SRE Mini-Project)
Generates controlled synthetic resource stress to test monitoring scripts.

Options:
  --cpu [workers]       Generate CPU load using spin-loops (default: ${DEFAULT_CPU_WORKERS} workers)
  --memory [mb]         Allocate Memory in MB (default: ${DEFAULT_MEM_MB}MB)
  --disk [mb]           Write Disk dummy files in MB (default: ${DEFAULT_DISK_MB}MB)
  --all                 Enable CPU, Memory, and Disk stress simultaneously
  --duration <seconds>  Duration in seconds to run stress before auto-cleanup (default: ${DEFAULT_DURATION}s)
  --cleanup             Clean up any remaining temporary files or background workers
  -h, --help            Show this help message and exit

Examples:
  # Stress 2 CPU cores for 15 seconds
  $(basename "$0") --cpu 2 --duration 15

  # Stress 512MB RAM and 1000MB Disk for 20 seconds
  $(basename "$0") --memory 512 --disk 1000 --duration 20

  # Stress all subsystems for 10 seconds
  $(basename "$0") --all --duration 10
EOF
}

# ------------------------------------------------------------------------------
# Cleanup & Signal Traps
# ------------------------------------------------------------------------------

cleanup() {
    if [[ "$CLEANUP_DONE" == true ]]; then
        return
    fi
    CLEANUP_DONE=true
    echo ""
    echo "[stress_simulator] Cleaning up stress resources..."

    # Terminate background CPU spin workers
    for pid in "${WORKER_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done

    # Remove temporary stress directory
    if [[ -d "$STRESS_DIR" ]]; then
        rm -rf "$STRESS_DIR"
    fi

    echo "[stress_simulator] Cleanup complete."
}

trap cleanup SIGINT SIGTERM EXIT

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        # Default behavior if no flags: stress CPU for 10s
        STRESS_CPU=true
        return
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpu)
                STRESS_CPU=true
                if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
                    CPU_WORKERS="$2"
                    shift 2
                else
                    shift 1
                fi
                ;;
            --memory)
                STRESS_MEM=true
                if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
                    MEM_MB="$2"
                    shift 2
                else
                    shift 1
                fi
                ;;
            --disk)
                STRESS_DISK=true
                if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
                    DISK_MB="$2"
                    shift 2
                else
                    shift 1
                fi
                ;;
            --all)
                STRESS_CPU=true
                STRESS_MEM=true
                STRESS_DISK=true
                shift 1
                ;;
            --duration)
                if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
                    DURATION="$2"
                    shift 2
                else
                    echo "[ERROR] --duration requires a positive integer (seconds)" >&2
                    exit 1
                fi
                ;;
            --cleanup)
                rm -rf /tmp/health_check_stress_* 2>/dev/null || true
                echo "[stress_simulator] Cleaned existing stress files from /tmp."
                exit 0
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                echo "[ERROR] Unknown option: $1. Run with --help for options." >&2
                exit 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Stress Functions
# ------------------------------------------------------------------------------

start_cpu_stress() {
    local workers="$1"
    echo "[stress_simulator] Starting ${workers} CPU spin-loop worker(s)..."
    for ((i = 1; i <= workers; i++)); do
        (
            # Infinite spin loop consuming 100% of 1 core
            while true; do
                :
            done
        ) &
        WORKER_PIDS+=("$!")
    done
}

start_memory_stress() {
    local mb="$1"
    echo "[stress_simulator] Allocating ${mb}MB of memory..."
    mkdir -p "$STRESS_DIR"
    
    # Try using /dev/shm (shared memory tmpfs) if available on Linux, else fallback to standard /tmp
    local target_shm="/dev/shm"
    if [[ -d "$target_shm" && -w "$target_shm" ]]; then
        dd if=/dev/zero of="${target_shm}/health_check_mem_stress_$$" bs=1M count="$mb" status=none 2>/dev/null || true
    else
        # Fallback allocation in temp directory
        dd if=/dev/zero of="${STRESS_DIR}/mem_dummy.img" bs=1M count="$mb" status=none 2>/dev/null || true
    fi
}

start_disk_stress() {
    local mb="$1"
    echo "[stress_simulator] Writing ${mb}MB dummy file to disk..."
    mkdir -p "$STRESS_DIR"
    dd if=/dev/zero of="${STRESS_DIR}/disk_stress.bin" bs=1M count="$mb" status=none 2>/dev/null || true
    echo "[stress_simulator] Disk dummy file generated at ${STRESS_DIR}/disk_stress.bin"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

main() {
    parse_args "$@"

    echo "=================================================="
    echo "  DevOps / SRE Mini-Project: Stress Simulator"
    echo "=================================================="
    echo "Duration    : ${DURATION} second(s)"
    echo "Stress CPU  : ${STRESS_CPU} (${CPU_WORKERS} workers)"
    echo "Stress Mem  : ${STRESS_MEM} (${MEM_MB}MB)"
    echo "Stress Disk : ${STRESS_DISK} (${DISK_MB}MB)"
    echo "Temp Dir    : ${STRESS_DIR}"
    echo "=================================================="

    mkdir -p "$STRESS_DIR"

    if [[ "$STRESS_CPU" == true ]]; then
        start_cpu_stress "$CPU_WORKERS"
    fi

    if [[ "$STRESS_MEM" == true ]]; then
        start_memory_stress "$MEM_MB"
    fi

    if [[ "$STRESS_DISK" == true ]]; then
        start_disk_stress "$DISK_MB"
    fi

    echo "[stress_simulator] Synthetic workload active. Running for ${DURATION}s (Press Ctrl+C to cancel)..."
    sleep "$DURATION"
    echo "[stress_simulator] Duration elapsed."
}

main "$@"
