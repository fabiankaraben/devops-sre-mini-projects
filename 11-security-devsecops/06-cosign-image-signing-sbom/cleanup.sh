#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Resource Teardown for Mini-Project 11-06
# ==============================================================================
# Stops and removes Docker Compose services, local OCI registry container & volumes,
# generated cryptographic keys, SBOM reports, and optionally purges Docker images.
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
cd "$SCRIPT_DIR"

PURGE_IMAGES=false

for arg in "$@"; do
    case "$arg" in
        --all|--purge-images)
            PURGE_IMAGES=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, --purge-images   Remove built container images and base tooling images"
            echo "  --help, -h              Show this help message"
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
echo "  🧹 Cleaning Up Cosign & SBOM Sandbox Resources"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Determine Docker Compose CLI syntax
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

# ------------------------------------------------------------------------------
# 1. Stop and Remove Containers, Networks, and Named Volumes
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}▶ [1/3] Tearing down containers, network, and registry volume...${CLR_RESET}"

if [[ -n "$COMPOSE_CMD" ]] && [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    $COMPOSE_CMD down -v --remove-orphans >/dev/null 2>&1 || true
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Compose containers and networks stopped and removed."
    echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Named volume 'local_oci_registry_data' deleted."
else
    if command -v docker >/dev/null 2>&1; then
        docker rm -f local-oci-registry secure-app-service >/dev/null 2>&1 || true
        docker volume rm local_oci_registry_data >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Direct Docker cleanup completed."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Optionally Purge Docker Container Images
# ------------------------------------------------------------------------------
if [ "$PURGE_IMAGES" = true ]; then
    echo -e "\n${CLR_YELLOW}▶ [2/3] Purging container images (sample apps, registry, cosign, syft)...${CLR_RESET}"
    if command -v docker >/dev/null 2>&1; then
        docker rmi -f \
            localhost:5001/secure-app:1.0.0 \
            localhost:5001/secure-app:tampered \
            localhost:5001/secure-app:unsigned \
            registry:2 \
            anchore/syft:latest \
            gcr.io/projectsigstore/cosign:latest >/dev/null 2>&1 || true
        echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Docker images purged successfully."
    fi
else
    echo -e "\n${CLR_YELLOW}▶ [2/3] Skipping image deletion (use --all or --purge-images to delete them).${CLR_RESET}"
fi

# ------------------------------------------------------------------------------
# 3. Clean Generated Cryptographic Keys, Reports & Python Artifacts
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ [3/3] Removing cryptographic keys, generated reports, and Python cache...${CLR_RESET}"
rm -rf "$SCRIPT_DIR/reports"
rm -f "$SCRIPT_DIR/cosign.key" "$SCRIPT_DIR/cosign.pub" "$SCRIPT_DIR/cosign.password"
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.py[cod]" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -type f -name "*.log" -delete 2>/dev/null || true
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Cryptographic keys (cosign.key, cosign.pub) removed."
echo -e "  [${CLR_GREEN}OK${CLR_RESET}] Generated SBOM and attestation reports cleaned."

echo -e "\n${CLR_GREEN}${CLR_BOLD}✨ Environment is completely clean! Ready for subsequent projects.${CLR_RESET}\n"
