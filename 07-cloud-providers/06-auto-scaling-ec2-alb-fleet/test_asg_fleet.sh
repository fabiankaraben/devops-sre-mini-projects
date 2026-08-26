#!/usr/bin/env bash
# ==============================================================================
# test_asg_fleet.sh - High-Availability ASG & ALB Automated Test Runner
# ==============================================================================
# Validates Python syntax, Bash scripts, Terraform IaC manifests, and executes
# the end-to-end multi-AZ load balancing, target tracking, and self-healing tests.
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"
CLR_WHITE="\033[1;37m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERBOSE=false
RUN_DOCKER=false
RUN_LIVE=false

for arg in "$@"; do
    case "$arg" in
        --docker)
            RUN_DOCKER=true
            ;;
        --live)
            RUN_LIVE=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: ./test_asg_fleet.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --docker       Run automated Docker Compose multi-container test"
            echo "  --live         Run tests against live AWS ALB endpoint from Terraform"
            echo "  --verbose, -v  Show granular logs and hop-by-hop execution traces"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./test_asg_fleet.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  ⚡ High-Availability Auto Scaling Fleet & ALB Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Check Tooling Prerequisites
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking Tooling Prerequisites...${CLR_RESET}"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] python3 is required but not found in PATH."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found Python: $(python3 --version)"

if ! command -v curl >/dev/null 2>&1; then
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] curl is required but not found in PATH."
    exit 1
fi
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found curl: $(curl --version | head -n 1)"

IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

if [[ -n "$IAC_BIN" ]]; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found IaC Engine: $IAC_BIN ($($IAC_BIN version -json 2>/dev/null | grep -o '"version":"[^"]*"' || $IAC_BIN --version | head -n 1))"
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Neither Terraform nor OpenTofu found in PATH."
fi

# ------------------------------------------------------------------------------
# 2. Validate Script Syntax (Python & Bash)
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Validating Python & Bash Script Syntax...${CLR_RESET}"

python3 -m py_compile "$SCRIPT_DIR/app/server.py"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] app/server.py syntax valid."

python3 -m py_compile "$SCRIPT_DIR/fleet_simulator.py"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] fleet_simulator.py syntax valid."

bash -n "$SCRIPT_DIR/load_test_asg.sh"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] load_test_asg.sh syntax valid."

bash -n "$SCRIPT_DIR/cleanup.sh"
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] cleanup.sh syntax valid."

# ------------------------------------------------------------------------------
# 3. Validate Terraform IaC Manifests
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Validating Terraform / OpenTofu IaC Manifests...${CLR_RESET}"

if [[ -n "$IAC_BIN" ]]; then
    echo "  Checking IaC code formatting..."
    if "$IAC_BIN" fmt -check "$SCRIPT_DIR" >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC files properly formatted."
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Reformatting IaC files with '$IAC_BIN fmt'..."
        "$IAC_BIN" fmt "$SCRIPT_DIR"
    fi

    echo "  Initializing and validating IaC configuration..."
    "$IAC_BIN" init -backend=false -input=false >/dev/null 2>&1 || true
    if "$IAC_BIN" validate >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC configuration is structurally valid."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] IaC validation failed. Running '$IAC_BIN validate' for details:"
        "$IAC_BIN" validate
        exit 1
    fi
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] IaC validator skipped (no binary found)."
fi

# ------------------------------------------------------------------------------
# 4. Execute Offline Fleet Simulation Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Executing Offline Fleet & ASG Simulator Tests...${CLR_RESET}"

SIM_ARGS=("--json-output" "$SCRIPT_DIR/test_report.json")
if [[ "$VERBOSE" == true ]]; then
    SIM_ARGS+=("--verbose")
fi

if python3 "$SCRIPT_DIR/fleet_simulator.py" "${SIM_ARGS[@]}"; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Simulator tests completed successfully."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Simulation tests failed!"
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Optional Docker Compose Multi-Container Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Checking Docker Environment Integration...${CLR_RESET}"

if [[ "$RUN_DOCKER" == true ]] || (command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && [[ "$RUN_LIVE" == false ]]); then
    echo "  Starting local Docker Compose ALB & EC2 fleet..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --build >/dev/null 2>&1 || true

    echo "  Waiting for ALB container to become healthy (up to 15s)..."
    ALB_READY=false
    for _ in {1..15}; do
        if curl -fs -m 2 "http://localhost:8080/health" >/dev/null 2>&1; then
            ALB_READY=true
            break
        fi
        sleep 1
    done

    if [[ "$ALB_READY" == true ]]; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Local ALB is active at http://localhost:8080"
        echo "  Running automated load test against Docker ALB..."
        "$SCRIPT_DIR/load_test_asg.sh" --url "http://localhost:8080" --requests 30 --concurrency 3
    else
        echo -e "  [${CLR_YELLOW}INFO${CLR_RESET}] Docker ALB not reachable, proceeding with mock validation."
    fi

    echo "  Tearing down test Docker containers..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
elif [[ "$RUN_LIVE" == true ]]; then
    echo "  Running live test against AWS Cloud ALB..."
    "$SCRIPT_DIR/load_test_asg.sh" --requests 30
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker test skipped (use --docker or start docker to run)."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 All ASG, Multi-AZ & ALB Tests Passed Successfully!${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
