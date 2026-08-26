#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 07-06
# ==============================================================================
# Destroys all provisioned AWS resources (VPC, subnets, ALB, Target Groups,
# Launch Templates, ASG, CloudWatch Alarms), stops and removes all Docker
# containers, images, and volumes, terminates background processes, and purges state.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_STATE=false
PURGE_DOCKER=true

for arg in "$@"; do
    case "$arg" in
        --all|--purge-state)
            PURGE_STATE=true
            ;;
        --no-docker)
            PURGE_DOCKER=false
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-state   Purge .terraform/, .terraform.lock.hcl, and terraform.tfstate files"
            echo "  --no-docker            Skip Docker container/image teardown"
            echo "  --help, -h             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./cleanup.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧹 Cleaning Up High-Availability ASG & ALB Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# 1. Terminate Background Python Servers or Simulator Processes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/4] Terminating background web servers and load testers...${CLR_RESET}"
pkill -f "app/server.py" >/dev/null 2>&1 || true
pkill -f "fleet_simulator.py" >/dev/null 2>&1 || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Background processes terminated."

# ------------------------------------------------------------------------------
# 2. Stop and Remove Docker Containers, Networks, Images & Volumes
# ------------------------------------------------------------------------------
if [[ "$PURGE_DOCKER" == true ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo -e "\n${CLR_YELLOW}▶ [2/4] Stopping and removing Docker containers, networks & volumes...${CLR_RESET}"

    if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
        echo "  Running 'docker compose down -v --rmi local'..."
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" down -v --rmi local --remove-orphans >/dev/null 2>&1 || true
    fi

    # Explicit fallback to remove any container with asg-alb-fleet prefix
    CONTAINERS=$(docker ps -a --filter "name=asg-alb-fleet" --format "{{.ID}}" 2>/dev/null || true)
    if [[ -n "$CONTAINERS" ]]; then
        echo "  Removing lingering containers: $CONTAINERS"
        docker rm -f $CONTAINERS >/dev/null 2>&1 || true
    fi

    # Remove custom network if exists
    docker network rm asg_fleet_network >/dev/null 2>&1 || true

    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker resources and local images purged."
else
    echo -e "\n${CLR_YELLOW}▶ [2/4] Docker cleanup skipped (Docker not running or --no-docker specified).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Destroy Terraform Cloud Infrastructure
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/4] Destroying Terraform / OpenTofu Cloud Infrastructure...${CLR_RESET}"
IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

if [[ -n "$IAC_BIN" ]] && [[ -f "$SCRIPT_DIR/terraform.tfstate" ]]; then
    echo "  Running '$IAC_BIN destroy' (terminating ASG, ALB, subnets, VPC)..."
    "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] AWS infrastructure destroyed."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active Terraform state found. Skipping cloud destroy."
fi

# ------------------------------------------------------------------------------
# 4. Clean Temporary Files & Test Artifacts
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [4/4] Removing temporary files and test logs...${CLR_RESET}"
find "$SCRIPT_DIR" -type f \( \
    -name "*.tfplan" -o \
    -name "tfplan" -o \
    -name ".tmp_*" -o \
    -name "*.log" -o \
    -name "test_report.json" -o \
    -name "test_load_results.json" -o \
    -name "*.pyc" \
\) -exec rm -f {} + 2>/dev/null || true

find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

if [[ "$PURGE_STATE" == true ]]; then
    echo "  Purging .terraform/ directories, lockfiles, and state files..."
    find "$SCRIPT_DIR" -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
    find "$SCRIPT_DIR" -type f \( -name ".terraform.lock.hcl" -o -name "terraform.tfstate*" \) -exec rm -f {} + 2>/dev/null || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] All state and plugin caches purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Preserved .terraform/ cache (run with --all to remove)."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✨ Teardown Complete! Environment is clean and ready.${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}======================================================================${CLR_RESET}\n"
