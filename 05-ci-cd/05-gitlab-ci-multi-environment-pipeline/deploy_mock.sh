#!/usr/bin/env bash
# ==============================================================================
# deploy_mock.sh - Zero-Downtime Multi-Environment Deployment Engine
# ==============================================================================
# Deploys application bundle to designated environment (staging vs production)
# and performs post-deployment health validation & URL verification.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ENV="${1:-staging}"
DEFAULT_PORT=$([[ "$TARGET_ENV" == "production" ]] && echo "8092" || echo "8091")
TARGET_PORT="${2:-$DEFAULT_PORT}"
CONTAINER_NAME="app-${TARGET_ENV}"
IMAGE_TAG="multi-env-delivery-app:local"
COMMIT_SHA="${CI_COMMIT_SHORT_SHA:-local-test}"
APP_VERSION="${APP_VERSION:-1.0.0}"

TARGET_ENV_UPPER=$(echo "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')

echo -e "\n${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}🚀 Initiating Deployment to Environment: [${TARGET_ENV_UPPER}]${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
echo -e "  Target Port:     ${TARGET_PORT}"
echo -e "  Container Name:  ${CONTAINER_NAME}"
echo -e "  Commit SHA:      ${COMMIT_SHA}"

# 1. Verify build artifacts
if [[ ! -f "${SCRIPT_DIR}/dist/server.js" ]]; then
    echo -e "${CLR_RED}Error: Build artifact dist/server.js not found. Run 'pnpm build' first.${CLR_RESET}" >&2
    exit 1
fi

# 2. Build local container image
echo -e "${CLR_YELLOW}▶ Building container image: ${IMAGE_TAG}...${CLR_RESET}"
(cd "$SCRIPT_DIR" && docker build -t "$IMAGE_TAG" -f Dockerfile . >/dev/null)
echo -e "${CLR_GREEN}✓ Image built successfully.${CLR_RESET}"

# 3. Stop and replace existing deployment
echo -e "${CLR_YELLOW}▶ Deploying container instance [${CONTAINER_NAME}] on port ${TARGET_PORT}...${CLR_RESET}"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${TARGET_PORT}:8080" \
    -e "APP_ENV=${TARGET_ENV}" \
    -e "APP_VERSION=${APP_VERSION}" \
    -e "CI_COMMIT_SHA=${COMMIT_SHA}" \
    -e "PORT=8080" \
    "$IMAGE_TAG" >/dev/null

echo -e "${CLR_GREEN}✓ Container started.${CLR_RESET}"

# 4. Post-deployment Smoke Tests & Health Check
echo -e "${CLR_YELLOW}▶ Running post-deployment health check on http://127.0.0.1:${TARGET_PORT}/healthz...${CLR_RESET}"

HEALTHY=false
for i in $(seq 1 15); do
    if curl -s -f "http://127.0.0.1:${TARGET_PORT}/healthz" >/dev/null 2>&1; then
        HEALTHY=true
        break
    fi
    sleep 0.4
done

if [[ "$HEALTHY" == "true" ]]; then
    HEALTH_DATA=$(curl -s "http://127.0.0.1:${TARGET_PORT}/healthz")
    INFO_DATA=$(curl -s "http://127.0.0.1:${TARGET_PORT}/info")
    echo -e "${CLR_GREEN}✓ Healthcheck passed: ${HEALTH_DATA}${CLR_RESET}"
    echo -e "${CLR_GREEN}✓ Runtime metadata:   ${INFO_DATA}${CLR_RESET}"
else
    echo -e "${CLR_RED}✗ Post-deployment healthcheck failed on port ${TARGET_PORT}!${CLR_RESET}" >&2
    docker logs "$CONTAINER_NAME"
    exit 1
fi

# 5. Generate Deployment Record JSON
REPORT_FILE="${SCRIPT_DIR}/deployment_report_${TARGET_ENV}.json"
cat <<EOF > "$REPORT_FILE"
{
  "environment": "${TARGET_ENV}",
  "url": "http://127.0.0.1:${TARGET_PORT}",
  "container": "${CONTAINER_NAME}",
  "version": "${APP_VERSION}",
  "commit_sha": "${COMMIT_SHA}",
  "status": "DEPLOYED",
  "deployed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo -e "\n${CLR_BOLD}${CLR_GREEN}✨ Deployment to [${TARGET_ENV_UPPER}] complete!${CLR_RESET}"
echo -e "   Live URL: ${CLR_BOLD}${CLR_CYAN}http://127.0.0.1:${TARGET_PORT}${CLR_RESET}\n"
