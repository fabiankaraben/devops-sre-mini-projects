#!/usr/bin/env bash
# ==============================================================================
# Script Name: watchdog.sh
# Description: POSIX CLI Shell Wrapper for Process Watchdog Daemon.
#              Provides commands to start, inspect status, stop, and configure
#              process supervision thresholds.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_PY="${SCRIPT_DIR}/watchdog.py"

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Process Watchdog Daemon Wrapper (DevOps / SRE Mini-Project)
Monitors, supervises, and automatically recovers failed background services.

Commands:
  start                     Start watchdog in foreground (or background with --daemon)
  status                    Display current status of supervisor and supervised process
  stop                      Gracefully terminate running watchdog and child processes

Options:
  --command <cmd>           Command string to execute and supervise (default: python3 flaky_service.py)
  --http-check <url>        HTTP healthcheck URL probe (default: http://127.0.0.1:8080/healthz)
  --interval <seconds>      Polling check interval (default: 2.0s)
  --max-restarts <count>    Max restarts permitted in window before flapping (default: 3)
  --window <seconds>        Sliding time window for flapping rate-limit (default: 60s)
  --daemon                  Launch watchdog detached into background
  -h, --help                Show this help message and exit

Examples:
  # Start supervising the flaky HTTP service
  $(basename "$0") start --http-check http://127.0.0.1:8080/healthz

  # Inspect live supervisor status in JSON
  $(basename "$0") status

  # Stop watchdog and supervised processes
  $(basename "$0") stop
EOF
}

COMMAND_ARG="start"
DAEMON_MODE=false
EXTRA_ARGS=()

if [[ $# -gt 0 ]]; then
    case "$1" in
        start)
            COMMAND_ARG="start"
            shift
            ;;
        status)
            exec python3 "$WATCHDOG_PY" --status
            ;;
        stop)
            exec python3 "$WATCHDOG_PY" --stop
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon)
            DAEMON_MODE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ "$DAEMON_MODE" == true ]]; then
    echo "[watchdog.sh] Launching Process Watchdog in background daemon mode..."
    nohup python3 "$WATCHDOG_PY" "${EXTRA_ARGS[@]}" > "${SCRIPT_DIR}/watchdog.log" 2>&1 &
    WATCHDOG_BG_PID=$!
    echo "[watchdog.sh] Watchdog running with PID ${WATCHDOG_BG_PID}. Log: ${SCRIPT_DIR}/watchdog.log"
else
    exec python3 "$WATCHDOG_PY" "${EXTRA_ARGS[@]}"
fi
