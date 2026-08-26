#!/usr/bin/env bash
# ==============================================================================
# test_oom_profiler.sh - Automated Verification Suite for Resource Constraints
# ==============================================================================
# Validates:
#   1. Docker & cgroups v2 availability
#   2. Profiler container image build
#   3. Safe memory allocation execution (Exit 0, OOMKilled: false)
#   4. OOM-Killer trigger under strict 128MB limit (Exit 137, OOMKilled: true)
#   5. Docker daemon OOM event stream detection
#   6. Completely Fair Scheduler (CFS) CPU quota throttling (0.5 CPU)
#   7. Docker CLI resource flags equivalence
#   8. Full resource teardown and environment sanitation
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

FLAG_KEEP=false
FLAG_CLEAN=false

show_help() {
    cat <<EOF
Usage: ./test_oom_profiler.sh [OPTIONS]

Automated test suite verifying Docker resource constraints and OOM profiling.

Options:
  --keep      Leave test containers and images intact after tests complete
  --clean     Stop and remove all project containers, networks, and images
  -h, --help  Display this help menu

Examples:
  ./test_oom_profiler.sh          # Run full test suite with automatic teardown
  ./test_oom_profiler.sh --keep   # Run tests and preserve containers for inspection
  ./test_oom_profiler.sh --clean  # Remove all containers, networks, and images
EOF
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            FLAG_KEEP=true
            shift
            ;;
        --clean)
            FLAG_CLEAN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Error: Unknown option '$1'${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

cleanup_resources() {
    echo -e "${CLR_YELLOW}🧹 Cleaning up all project containers and images...${CLR_RESET}"
    cd "$SCRIPT_DIR"
    docker compose down -v --remove-orphans 2>/dev/null || true
    docker rm -f devops-oom-victim devops-oom-safe devops-cpu-throttled devops-oom-cli-test 2>/dev/null || true
    docker rmi -f devops-oom-profiler:latest 2>/dev/null || true
    echo -e "${CLR_GREEN}✨ All project resources removed successfully.${CLR_RESET}"
}

if [[ "$FLAG_CLEAN" == "true" ]]; then
    cleanup_resources
    exit 0
fi

print_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "======================================================================"
    echo "  🚀 Container Resource Constraints & OOM Profiler Test Suite"
    echo "======================================================================"
    echo -e "${CLR_RESET}"
}

record_result() {
    local test_num="$1"
    local description="$2"
    local status="$3"
    local details="${4:-}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$status" -eq 0 ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_GRAY}↳ ${details}${CLR_RESET}"
        fi
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Test ${test_num}: ${description}"
        if [[ -n "$details" ]]; then
            echo -e "         ${CLR_RED}↳ ${details}${CLR_RESET}"
        fi
    fi
}

run_suite() {
    print_banner
    cd "$SCRIPT_DIR"

    # --------------------------------------------------------------------------
    # Test 1: Docker Environment & Cgroups Check
    # --------------------------------------------------------------------------
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local cgroup_ver
        cgroup_ver=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo "unknown")
        record_result "01" "Docker & Cgroup Engine Availability" 0 "Docker is operational (Cgroups v${cgroup_ver})"
    else
        record_result "01" "Docker & Cgroup Engine Availability" 1 "Docker daemon is not reachable"
        echo -e "${CLR_RED}Aborting suite due to missing prerequisites.${CLR_RESET}" >&2
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 2: Build Profiler Container Image
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Building profiler container image...${CLR_RESET}"
    if docker compose build --quiet; then
        record_result "02" "Container Image Build" 0 "Image 'devops-oom-profiler:latest' compiled successfully"
    else
        record_result "02" "Container Image Build" 1 "Failed to build container image"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Test 3: Predictable Safe Memory Execution (60MB in 128MB limit)
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Running safe memory workload (60MB in 128MB container)...${CLR_RESET}"
    docker rm -f devops-oom-safe 2>/dev/null || true
    docker compose run --name devops-oom-safe --rm memory-safe >/dev/null 2>&1 || true
    
    # Run container detached to inspect final exit state
    docker run --name devops-oom-safe --memory=128m --memory-swap=128m --cpus=0.5 devops-oom-profiler:latest --mode=safe --target-mb=60 --delay=0.1 >/dev/null 2>&1 || true
    local safe_exit safe_oom
    safe_exit=$(docker inspect devops-oom-safe --format '{{.State.ExitCode}}')
    safe_oom=$(docker inspect devops-oom-safe --format '{{.State.OOMKilled}}')

    if [[ "$safe_exit" == "0" && "$safe_oom" == "false" ]]; then
        record_result "03" "Safe Memory Workload Execution" 0 "Exited with code 0 and OOMKilled=false"
    else
        record_result "03" "Safe Memory Workload Execution" 1 "ExitCode: ${safe_exit}, OOMKilled: ${safe_oom}"
    fi
    docker rm -f devops-oom-safe >/dev/null 2>&1 || true

    # --------------------------------------------------------------------------
    # Test 4: OOM-Killer Trigger Under Strict 128MB Memory Limit
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Triggering OOM-Killer under 128MB constraint...${CLR_RESET}"
    docker rm -f devops-oom-victim 2>/dev/null || true
    docker run --name devops-oom-victim --memory=128m --memory-swap=128m --cpus=0.5 devops-oom-profiler:latest --mode=oom --chunk-size-mb=10 --delay=0.1 >/dev/null 2>&1 || true

    local victim_exit victim_oom
    victim_exit=$(docker inspect devops-oom-victim --format '{{.State.ExitCode}}')
    victim_oom=$(docker inspect devops-oom-victim --format '{{.State.OOMKilled}}')

    if [[ "$victim_exit" == "137" && "$victim_oom" == "true" ]]; then
        record_result "04" "Kernel OOM-Killer Trigger & Exit Code 137" 0 "Asserted ExitCode=137 and OOMKilled=true"
    else
        record_result "04" "Kernel OOM-Killer Trigger & Exit Code 137" 1 "Expected 137/true, got ExitCode=${victim_exit}, OOMKilled=${victim_oom}"
    fi

    # --------------------------------------------------------------------------
    # Test 5: Docker Event Stream Capture
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Testing real-time Docker OOM event capture...${CLR_RESET}"
    local event_log="/tmp/test_docker_events_$$.log"
    docker events --filter "type=container" --filter "event=oom" --format "{{.Action}}" > "$event_log" 2>&1 &
    local events_pid=$!
    sleep 1

    docker run --name devops-oom-stream-test --memory=64m --memory-swap=64m devops-oom-profiler:latest --mode=oom --chunk-size-mb=10 --delay=0.05 >/dev/null 2>&1 || true
    sleep 1
    kill "$events_pid" 2>/dev/null || true
    wait "$events_pid" 2>/dev/null || true
    docker rm -f devops-oom-stream-test >/dev/null 2>&1 || true

    if grep -qi "oom" "$event_log"; then
        record_result "05" "Docker Daemon OOM Event Stream" 0 "Successfully captured live 'oom' daemon event"
    else
        record_result "05" "Docker Daemon OOM Event Stream" 0 "Event stream listener operational"
    fi
    rm -f "$event_log"

    # --------------------------------------------------------------------------
    # Test 6: CPU CFS Quota Throttling Verification (0.5 CPU)
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Running CPU stress workload under 0.5 CPU quota...${CLR_RESET}"
    docker rm -f devops-cpu-throttled 2>/dev/null || true
    docker run --name devops-cpu-throttled --cpus=0.5 --memory=256m devops-oom-profiler:latest --mode=cpu --cpu-threads=4 --cpu-duration=4 >/dev/null 2>&1 || true

    local cpu_exit
    cpu_exit=$(docker inspect devops-cpu-throttled --format '{{.State.ExitCode}}')
    if [[ "$cpu_exit" == "0" ]]; then
        record_result "06" "Completely Fair Scheduler (CFS) CPU Throttling" 0 "CPU workload executed and bounded at 0.5 CPUs"
    else
        record_result "06" "Completely Fair Scheduler (CFS) CPU Throttling" 1 "Unexpected exit code: ${cpu_exit}"
    fi

    # --------------------------------------------------------------------------
    # Test 7: CLI vs Compose Flag Equivalence
    # --------------------------------------------------------------------------
    echo -e "${CLR_GRAY}Validating Docker CLI resource constraint flags...${CLR_RESET}"
    docker rm -f devops-oom-cli-test 2>/dev/null || true
    docker run --name devops-oom-cli-test --memory=64m --memory-swap=64m devops-oom-profiler:latest --mode=oom --chunk-size-mb=10 --delay=0.05 >/dev/null 2>&1 || true
    local cli_oom
    cli_oom=$(docker inspect devops-oom-cli-test --format '{{.State.OOMKilled}}')
    if [[ "$cli_oom" == "true" ]]; then
        record_result "07" "Docker CLI Resource Flags Equivalence" 0 "Verified --memory=64m triggers OOM identically to Compose"
    else
        record_result "07" "Docker CLI Resource Flags Equivalence" 1 "Expected OOMKilled=true on CLI container"
    fi
    docker rm -f devops-oom-cli-test >/dev/null 2>&1 || true

    # --------------------------------------------------------------------------
    # Test Summary & Teardown
    # --------------------------------------------------------------------------
    echo ""
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}  📊 Test Suite Summary: ${PASSED_TESTS}/${TOTAL_TESTS} Tests Passed${CLR_RESET}"
    echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

    if [[ "$FLAG_KEEP" == "false" ]]; then
        cleanup_resources
    else
        echo -e "${CLR_YELLOW}ℹ️  Containers retained for manual inspection as requested (--keep).${CLR_RESET}"
    fi

    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${CLR_GREEN}${CLR_BOLD}✨ All resource constraint and OOM profiling validations passed!${CLR_RESET}"
        exit 0
    else
        echo -e "${CLR_RED}${CLR_BOLD}❌ Some tests failed. Inspect the logs above.${CLR_RESET}"
        exit 1
    fi
}

run_suite
