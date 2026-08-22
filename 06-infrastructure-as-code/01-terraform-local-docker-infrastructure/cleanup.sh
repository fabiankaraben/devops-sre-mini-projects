#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Complete Resource Teardown for Mini-Project 01
# ==============================================================================
# Destroys all Terraform-managed Docker resources (containers, networks,
# volumes, images) and removes temporary local state files.
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
PURGE_STATE=false

for arg in "$@"; do
    case "$arg" in
        --all|--purge-state)
            PURGE_STATE=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-state   Also purge .terraform/, .terraform.lock.hcl, and terraform.tfstate files"
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
echo "  🧹 Cleaning Up Terraform Local Docker Infrastructure"
echo "======================================================================"
echo -e "${CLR_RESET}"

# 1. Detect Terraform or OpenTofu binary
IAC_BIN=""
if command -v terraform >/dev/null 2>&1; then
    IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
    IAC_BIN="tofu"
fi

# 2. Attempt clean destroy via Terraform / OpenTofu if state exists
echo -e "${CLR_YELLOW}▶ [1/4] Destroying infrastructure via IaC engine...${CLR_RESET}"
if [[ -n "$IAC_BIN" ]] && [[ -f "$SCRIPT_DIR/terraform.tfstate" ]]; then
    echo "  Running '$IAC_BIN destroy -auto-approve' in $SCRIPT_DIR..."
    if (cd "$SCRIPT_DIR" && "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1); then
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Terraform resources destroyed successfully."
    else
        echo -e "  [${CLR_YELLOW}WARN${CLR_RESET}] IaC destroy reported non-zero status; falling back to direct Docker cleanup."
    fi
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] No active terraform.tfstate found or IaC engine not installed. Proceeding to Docker check."
fi

# 3. Direct Docker resource cleanup (safeguard for orphaned containers/networks/volumes)
echo -e "\n${CLR_YELLOW}▶ [2/4] Purging project Docker containers, networks, and volumes...${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # Remove containers
    for container in "terraform-nginx-app" "custom-nginx-demo" "terraform-nginx-test"; do
        if docker ps -a --format '{{.Names}}' | grep -Eq "^${container}$"; then
            echo "  Removing container: ${container}"
            docker rm -f "${container}" >/dev/null 2>&1 || true
        fi
    done

    # Remove networks
    for net in "terraform-docker-net" "custom-docker-net"; do
        if docker network ls --format '{{.Name}}' | grep -Eq "^${net}$"; then
            echo "  Removing network: ${net}"
            docker network rm "${net}" >/dev/null 2>&1 || true
        fi
    done

    # Remove volumes
    for vol in "terraform-nginx-data" "custom-nginx-vol"; do
        if docker volume ls --format '{{.Name}}' | grep -Eq "^${vol}$"; then
            echo "  Removing volume: ${vol}"
            docker volume rm "${vol}" >/dev/null 2>&1 || true
        fi
    done

    # Remove test images
    for img in "nginx:1.27-alpine" "nginx:alpine"; do
        if docker images --format '{{.Repository}}:{{.Tag}}' | grep -Eq "^${img}$"; then
            echo "  Removing image: ${img}"
            docker rmi -f "${img}" >/dev/null 2>&1 || true
        fi
    done
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker resources checked and purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Docker daemon not running or not reachable."
fi

# 4. Remove local temporary plan files and test artifacts
echo -e "\n${CLR_YELLOW}▶ [3/4] Removing temporary plan files and test artifacts...${CLR_RESET}"
rm -f "$SCRIPT_DIR"/*.tfplan "$SCRIPT_DIR"/tfplan "$SCRIPT_DIR"/.tmp_* "$SCRIPT_DIR"/*.log
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Temporary files removed."

# 5. Purge state and provider plugins if requested
echo -e "\n${CLR_YELLOW}▶ [4/4] State & plugin cache cleanup...${CLR_RESET}"
if [[ "$PURGE_STATE" == true ]]; then
    echo "  Purging .terraform/ directory, .terraform.lock.hcl, and terraform.tfstate files..."
    rm -rf "$SCRIPT_DIR/.terraform"
    rm -f "$SCRIPT_DIR/.terraform.lock.hcl"
    rm -f "$SCRIPT_DIR"/terraform.tfstate*
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] State and plugin caches purged."
else
    echo -e "  [${CLR_GRAY}INFO${CLR_RESET}] Keeping .terraform/ cache and state (use '--all' to remove them)."
fi

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ CLEANUP COMPLETE: All project resources have been successfully purged.${CLR_RESET}\n"
