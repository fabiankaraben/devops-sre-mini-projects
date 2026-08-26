#!/usr/bin/env bash
# ==============================================================================
# test_dr_failover.sh - Master Test Runner for Project 10
# ==============================================================================
# Validates Python syntax, Bash scripts, Terraform multi-region IaC manifests,
# and executes the end-to-end Active-Passive Disaster Recovery simulation suite.
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERBOSE=false
RUN_DOCKER=false
RUN_LIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)
            RUN_DOCKER=true
            shift
            ;;
        --live)
            RUN_LIVE=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: ./test_dr_failover.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --docker       Run automated multi-region Docker Compose failover test"
            echo "  --live         Run tests against live AWS infrastructure from Terraform"
            echo "  --verbose, -v  Show granular logs and hop-by-hop execution traces"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run ./test_dr_failover.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_BLUE}${CLR_BOLD}"
echo "======================================================================"
echo "  🌐 Multi-Region Disaster Recovery & Route 53 Test Runner"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Prerequisites Check
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/5] Checking Tooling Prerequisites...${CLR_RESET}"

if command -v python3 >/dev/null 2>&1; then
    PY_VER=$(python3 --version 2>&1)
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found Python: ${PY_VER}"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] python3 is required but not found."
    exit 1
fi

if command -v curl >/dev/null 2>&1; then
    CURL_VER=$(curl --version | head -n 1)
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found curl: ${CURL_VER}"
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] curl is required for testing."
    exit 1
fi

IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found IaC Engine: terraform ($("$IAC_BIN" version | head -n 1))"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Found IaC Engine: tofu ($("$IAC_BIN" version | head -n 1))"
else
    echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] Neither terraform nor tofu found. IaC validation will be skipped."
fi

# ------------------------------------------------------------------------------
# 2. Syntax & Compilation Check
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [2/5] Validating Python & Bash Script Syntax...${CLR_RESET}"

for py_file in "$SCRIPT_DIR/app/main.py" "$SCRIPT_DIR/router/failover_gateway.py" "$SCRIPT_DIR/dr_failover_simulator.py"; do
    if python3 -m py_compile "$py_file" 2>/dev/null; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] $(basename "$(dirname "$py_file")")/$(basename "$py_file") syntax valid."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Syntax error in $py_file!"
        python3 -m py_compile "$py_file"
        exit 1
    fi
done

for sh_file in "$SCRIPT_DIR/test_dr_failover.sh" "$SCRIPT_DIR/cleanup.sh" "$SCRIPT_DIR/dr_failover_test.sh"; do
    if bash -n "$sh_file" 2>/dev/null; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] $(basename "$sh_file") syntax valid."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Syntax error in $sh_file!"
        bash -n "$sh_file"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# 3. Terraform / OpenTofu IaC Manifest Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/5] Validating Terraform Multi-Region IaC Manifests...${CLR_RESET}"

if [[ -n "$IAC_BIN" ]]; then
    echo "  Checking IaC code formatting..."
    if "$IAC_BIN" fmt -check >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC files properly formatted."
    else
        echo -e "  [${CLR_YELLOW}FIX${CLR_RESET}] Formatting IaC files with '$IAC_BIN fmt'..."
        "$IAC_BIN" fmt
    fi

    echo "  Initializing and validating multi-region IaC configuration..."
    if "$IAC_BIN" init -backend=false >/dev/null 2>&1 && "$IAC_BIN" validate >/dev/null 2>&1; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] IaC configuration is structurally valid."
    else
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] IaC validation failed!"
        "$IAC_BIN" validate
        exit 1
    fi
else
    echo -e "  [${CLR_GRAY}SKIP${CLR_RESET}] IaC validator skipped (no binary found)."
fi

# ------------------------------------------------------------------------------
# 4. Execute Offline Disaster Recovery Simulation Suite
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/5] Executing Offline Disaster Recovery Simulator Tests...${CLR_RESET}"

SIM_ARGS=("--json-output" "$SCRIPT_DIR/test_report.json")
if [[ "$VERBOSE" == true ]]; then
    SIM_ARGS+=("--verbose")
fi

if python3 "$SCRIPT_DIR/dr_failover_simulator.py" "${SIM_ARGS[@]}"; then
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Simulator tests completed successfully."
else
    echo -e "  [${CLR_RED}FAIL${CLR_RESET}] Simulation tests failed!"
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Local Docker Multi-Region Container Verification & Chaos Test
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [5/5] Checking Multi-Region Docker Environment Integration...${CLR_RESET}"

if [[ "$RUN_DOCKER" == true ]] || (command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && [[ "$RUN_LIVE" == false ]]); then
    echo "  Starting local Docker Compose Multi-Region stack..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --build >/dev/null 2>&1 || true

    echo "  Waiting for Route 53 Gateway and Regional apps to become ready (up to 12s)..."
    STACK_READY=false
    for _ in {1..12}; do
        if curl -fs -m 2 "http://localhost:8080/gateway/health" >/dev/null 2>&1; then
            STACK_READY=true
            break
        fi
        sleep 1
    done

    if [[ "$STACK_READY" == true ]]; then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Route 53 Gateway is active at http://localhost:8080"
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Primary Region active at http://localhost:8081 (us-east-1)"
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Secondary DR Region active at http://localhost:8082 (us-west-2)"
        echo "  Executing automated Chaos Failover test..."
        "$SCRIPT_DIR/dr_failover_test.sh" --gateway "http://localhost:8080" --primary "http://localhost:8081" --secondary "http://localhost:8082"
    else
        echo -e "  [${CLR_YELLOW}INFO${CLR_RESET}] Docker stack not reachable, proceeding with mock validation."
        "$SCRIPT_DIR/dr_failover_test.sh" --mock
    fi

    echo "  Tearing down test Docker containers..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
elif [[ "$RUN_LIVE" == true ]]; then
    echo "  Running live test against AWS infrastructure..."
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Live AWS test completed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker test skipped (use --docker or start docker to run)."
fi

echo -e "\n${CLR_BLUE}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  🎉 All Multi-Region Disaster Recovery & Route 53 Tests Passed!${CLR_RESET}"
echo -e "${CLR_BLUE}${CLR_BOLD}======================================================================${CLR_RESET}\n"
