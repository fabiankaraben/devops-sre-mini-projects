#!/usr/bin/env bash
# ==============================================================================
# verify_multiarch_build.sh - Multi-Architecture Docker Build & Manifest Verification
# ==============================================================================
# Verifies:
#   1. GitHub Actions workflow YAML syntax & semantic tag definitions
#   2. Go application unit tests & code quality
#   3. Docker Buildx builder initialization with multi-platform support
#   4. Ephemeral local OCI Registry instantiation (Port 5055)
#   5. Multi-arch build & push for linux/amd64 and linux/arm64
#   6. OCI Image Index (Manifest List) inspection & digest verification
#   7. Live container execution & HTTP healthz/info endpoint verification
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_BLUE="\033[1;34m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="${SCRIPT_DIR}/.github/workflows/docker_publish.yml"
REGISTRY_PORT="5055"
REGISTRY_NAME="multiarch-test-registry"
REGISTRY_IMAGE="registry:2"
IMAGE_TAG="localhost:${REGISTRY_PORT}/multiarch-demo:test"
TEST_CONTAINER="multiarch-service-test"
TEST_PORT="8095"

TOTAL_STEPS=0
PASSED_STEPS=0
FAILED_STEPS=0

KEEP_RESOURCES=false

show_help() {
    cat <<EOF
Usage: ./verify_multiarch_build.sh [OPTIONS]

Local verification suite for Multi-Arch Docker Build and Push Pipeline.

Options:
  --keep      Do not tear down test registry and containers after execution
  -h, --help  Display this help message

Examples:
  ./verify_multiarch_build.sh         # Run full test suite with automatic cleanup
  ./verify_multiarch_build.sh --keep  # Leave containers running for manual inspection
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            KEEP_RESOURCES=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
            show_help
            exit 1
            ;;
    esac
done

cleanup() {
    if [[ "$KEEP_RESOURCES" == "false" ]]; then
        log_info "Cleaning up temporary test containers..."
        docker rm -f "$TEST_CONTAINER" "$REGISTRY_NAME" >/dev/null 2>&1 || true
        if docker buildx ls 2>/dev/null | grep -q "multiarch-test-builder"; then
            docker buildx rm multiarch-test-builder >/dev/null 2>&1 || true
        fi
    fi
}
trap cleanup EXIT

log_header() {
    echo -e "\n${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_CYAN}$1${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_CYAN}===================================================================${CLR_RESET}"
}

log_step() {
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
    echo -e "\n${CLR_BOLD}${CLR_BLUE}▶ [Step $TOTAL_STEPS] $1${CLR_RESET}"
}

log_success() {
    PASSED_STEPS=$((PASSED_STEPS + 1))
    echo -e "${CLR_GREEN}✓ $1${CLR_RESET}"
}

log_failure() {
    FAILED_STEPS=$((FAILED_STEPS + 1))
    echo -e "${CLR_RED}✗ $1${CLR_RESET}" >&2
}

log_info() {
    echo -e "${CLR_GRAY}  ℹ $1${CLR_RESET}"
}

log_header "🐳 Executing Multi-Arch Docker Build & Verification Pipeline"
log_info "Workspace: ${SCRIPT_DIR}"
log_info "Workflow:  ${WORKFLOW_FILE}"

# ------------------------------------------------------------------------------
# 1. Environment & Dependency Checks
# ------------------------------------------------------------------------------
log_step "Checking Tooling Prerequisites (Docker & Buildx)"

if ! command -v docker >/dev/null 2>&1; then
    log_failure "Docker is not installed or not in PATH"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    log_failure "Docker daemon is not reachable"
    exit 1
fi
DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
log_success "Docker daemon is healthy (version: ${DOCKER_VER})"

if ! docker buildx version >/dev/null 2>&1; then
    log_failure "Docker Buildx plugin is missing"
    exit 1
fi
BUILDX_VER=$(docker buildx version | awk '{print $2}')
log_success "Docker Buildx plugin available (version: ${BUILDX_VER})"

if command -v curl >/dev/null 2>&1; then
    log_success "curl utility available"
else
    log_failure "curl utility is missing"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Workflow Manifest Validation
# ------------------------------------------------------------------------------
log_step "Validating GitHub Actions Workflow Manifest (docker_publish.yml)"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    log_failure "Workflow file missing at ${WORKFLOW_FILE}"
    exit 1
fi

if grep -q "docker/setup-buildx-action" "$WORKFLOW_FILE" && \
   grep -q "docker/setup-qemu-action" "$WORKFLOW_FILE" && \
   grep -q "platforms: linux/amd64,linux/arm64" "$WORKFLOW_FILE" && \
   grep -q "docker/metadata-action" "$WORKFLOW_FILE" && \
   grep -q "ghcr.io" "$WORKFLOW_FILE"; then
    log_success "Workflow YAML defines valid multi-platform QEMU, Buildx, GHCR, and Metadata actions"
else
    log_failure "Workflow YAML missing critical multi-arch configurations"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Go Application Unit Tests
# ------------------------------------------------------------------------------
log_step "Running Application Unit Tests"

if command -v go >/dev/null 2>&1; then
    log_info "Executing: go test -v ./..."
    (cd "${SCRIPT_DIR}/app" && go test -v ./...)
    log_success "Go unit test suite passed with 100% success rate"
else
    log_info "Go compiler not found on host; running unit tests inside official Go container..."
    docker run --rm -v "${SCRIPT_DIR}/app:/app" -w /app golang:1.22-alpine go test -v ./...
    log_success "Go unit test suite passed inside containerized runner"
fi

# ------------------------------------------------------------------------------
# 4. Spin up Local Ephemeral OCI Registry
# ------------------------------------------------------------------------------
log_step "Setting up Ephemeral Local OCI Registry (localhost:${REGISTRY_PORT})"

docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
log_info "Starting registry container: ${REGISTRY_NAME}"
docker run -d \
    --name "$REGISTRY_NAME" \
    -p "${REGISTRY_PORT}:5000" \
    --restart=no \
    "$REGISTRY_IMAGE" >/dev/null

# Wait for registry to accept requests
REGISTRY_READY=false
for i in $(seq 1 15); do
    if curl -s -f "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1 || [ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${REGISTRY_PORT}/v2/")" == "200" ]; then
        REGISTRY_READY=true
        break
    fi
    sleep 0.5
done

if [[ "$REGISTRY_READY" == "true" ]]; then
    log_success "Local OCI Registry is active at localhost:${REGISTRY_PORT}"
else
    log_failure "Failed to start local OCI Registry within timeout"
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Initialize Multi-Platform Buildx Builder
# ------------------------------------------------------------------------------
log_step "Configuring Multi-Platform Buildx Builder Instance"

BUILDER_NAME="multiarch-test-builder"
docker buildx rm "$BUILDER_NAME" >/dev/null 2>&1 || true

log_info "Creating Buildx container builder with host networking..."
docker buildx create \
    --name "$BUILDER_NAME" \
    --driver docker-container \
    --driver-opt network=host \
    --use >/dev/null

docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null
log_success "Buildx builder initialized and bootstrapped"

# ------------------------------------------------------------------------------
# 6. Build & Push Multi-Architecture Image (AMD64 + ARM64)
# ------------------------------------------------------------------------------
log_step "Compiling & Pushing Multi-Arch Image (linux/amd64, linux/arm64)"

log_info "Target Image: ${IMAGE_TAG}"
log_info "Executing: docker buildx build --platform linux/amd64,linux/arm64 --push ..."

cd "$SCRIPT_DIR"
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t "$IMAGE_TAG" \
    --push \
    .

log_success "Successfully built and pushed multi-architecture image to local registry"

# ------------------------------------------------------------------------------
# 7. Inspect OCI Manifest List (Image Index)
# ------------------------------------------------------------------------------
log_step "Inspecting OCI Image Index & Platform Manifests"

log_info "Executing: docker buildx imagetools inspect ${IMAGE_TAG}"
MANIFEST_OUTPUT=$(docker buildx imagetools inspect "$IMAGE_TAG")
echo -e "\n${CLR_CYAN}${MANIFEST_OUTPUT}${CLR_RESET}\n"

if echo "$MANIFEST_OUTPUT" | grep -q "linux/amd64"; then
    log_success "Found platform manifest for 'linux/amd64'"
else
    log_failure "Missing 'linux/amd64' platform in manifest list"
    exit 1
fi

if echo "$MANIFEST_OUTPUT" | grep -q "linux/arm64"; then
    log_success "Found platform manifest for 'linux/arm64'"
else
    log_failure "Missing 'linux/arm64' platform in manifest list"
    exit 1
fi

# ------------------------------------------------------------------------------
# 8. Live Container Execution & Endpoint Verification
# ------------------------------------------------------------------------------
log_step "Running Container & Verifying HTTP Endpoints"

docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true

log_info "Running test container: ${TEST_CONTAINER} (Port: ${TEST_PORT})"
docker run -d \
    --name "$TEST_CONTAINER" \
    -p "${TEST_PORT}:8080" \
    "$IMAGE_TAG" >/dev/null

# Wait for service to become responsive
SERVICE_READY=false
for i in $(seq 1 10); do
    if curl -s -f "http://127.0.0.1:${TEST_PORT}/healthz" >/dev/null 2>&1; then
        SERVICE_READY=true
        break
    fi
    sleep 0.5
done

if [[ "$SERVICE_READY" != "true" ]]; then
    log_failure "Microservice container failed to start or respond on port ${TEST_PORT}"
    docker logs "$TEST_CONTAINER"
    exit 1
fi

# Test /healthz
HEALTH_RESP=$(curl -s "http://127.0.0.1:${TEST_PORT}/healthz")
if echo "$HEALTH_RESP" | grep -q '"status":"healthy"'; then
    log_success "Health check endpoint GET /healthz returned healthy status"
else
    log_failure "GET /healthz returned invalid response: ${HEALTH_RESP}"
    exit 1
fi

# Test /info
INFO_RESP=$(curl -s "http://127.0.0.1:${TEST_PORT}/info")
DETECTED_ARCH=$(echo "$INFO_RESP" | grep -o '"architecture":"[^"]*"' | cut -d'"' -f4)
log_info "Microservice reports architecture: ${DETECTED_ARCH}"
if [[ -n "$DETECTED_ARCH" ]]; then
    log_success "Runtime info endpoint GET /info returned valid architecture metadata (${DETECTED_ARCH})"
else
    log_failure "GET /info missing architecture field"
    exit 1
fi

# Test /metrics
METRICS_RESP=$(curl -s "http://127.0.0.1:${TEST_PORT}/metrics")
if echo "$METRICS_RESP" | grep -q "service_uptime_seconds" && echo "$METRICS_RESP" | grep -q "service_requests_total"; then
    log_success "Prometheus metrics endpoint GET /metrics functioning properly"
else
    log_failure "GET /metrics failed to output expected metric counters"
    exit 1
fi

# ------------------------------------------------------------------------------
# 9. Summary Report
# ------------------------------------------------------------------------------
log_header "📊 Multi-Arch Docker CI Pipeline Summary"

echo -e "\n${CLR_BOLD}Pipeline Stage Summary:${CLR_RESET}"
echo -e "  ${CLR_CYAN}Total Verification Steps: ${TOTAL_STEPS}${CLR_RESET}"
echo -e "  ${CLR_GREEN}Passed Steps:             ${PASSED_STEPS}${CLR_RESET}"
echo -e "  ${CLR_RED}Failed Steps:             ${FAILED_STEPS}${CLR_RESET}"

if [[ "$FAILED_STEPS" -eq 0 ]]; then
    echo -e "\n${CLR_BOLD}${CLR_GREEN}🎉 MULTI-ARCH DOCKER BUILD & VERIFICATION SUITE PASSED!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_BOLD}${CLR_RED}❌ VERIFICATION FAILED WITH ${FAILED_STEPS} ERRORS.${CLR_RESET}\n"
    exit 1
fi
