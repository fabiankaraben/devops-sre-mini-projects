#!/usr/bin/env bash
# ==============================================================================
# run_gitlab_pipeline.sh - Local GitLab CI/CD Multi-Environment Pipeline Runner
# ==============================================================================
# Simulates full GitLab CI/CD pipeline execution:
#   1. Stage: Build (TypeScript Compilation & Artifact Generation)
#   2. Stage: Test (Unit Testing & Coverage Analysis)
#   3. Stage: Deploy-Staging (Automatic Deployment & URL Registration)
#   4. Stage: Deploy-Production (Manual Gate Approval & Verification)
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
WORKFLOW_FILE="${SCRIPT_DIR}/.gitlab-ci.yml"
STAGING_PORT="8091"
PROD_PORT="8092"

TOTAL_STEPS=0
PASSED_STEPS=0
FAILED_STEPS=0

KEEP_CONTAINERS=false
SKIP_PROD=false

show_help() {
    cat <<EOF
Usage: ./run_gitlab_pipeline.sh [OPTIONS]

Local runner simulating GitLab CI/CD Multi-Environment Delivery Pipeline.

Options:
  --no-prod   Stop after staging deployment (skip manual production gate)
  --keep      Leave staging and production containers running after tests
  -h, --help  Display this help message

Examples:
  ./run_gitlab_pipeline.sh          # Run full pipeline (Build -> Test -> Staging -> Prod)
  ./run_gitlab_pipeline.sh --keep   # Run full pipeline and leave live endpoints up
  ./run_gitlab_pipeline.sh --no-prod # Test only up to staging deployment
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            KEEP_CONTAINERS=true
            shift
            ;;
        --no-prod)
            SKIP_PROD=true
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

cleanup_containers() {
    if [[ "$KEEP_CONTAINERS" == "false" ]]; then
        log_info "Tearing down ephemeral deployment containers..."
        docker rm -f app-staging app-production >/dev/null 2>&1 || true
    fi
}
trap cleanup_containers EXIT

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

log_header "🦊 Executing GitLab CI Multi-Environment Delivery Pipeline"
log_info "Workspace: ${SCRIPT_DIR}"
log_info "Pipeline:  ${WORKFLOW_FILE}"

# ------------------------------------------------------------------------------
# 1. Environment Prerequisites
# ------------------------------------------------------------------------------
log_step "Checking Tooling Prerequisites (pnpm, Node, Docker, curl)"

if command -v pnpm >/dev/null 2>&1; then
    PNPM_VER=$(pnpm --version)
    log_success "Found pnpm (version: v${PNPM_VER})"
else
    log_failure "pnpm is not installed"
    exit 1
fi

if command -v node >/dev/null 2>&1; then
    NODE_VER=$(node --version)
    log_success "Found Node.js (version: ${NODE_VER})"
else
    log_failure "Node.js is not installed"
    exit 1
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    log_success "Found Docker daemon (version: ${DOCKER_VER})"
else
    log_failure "Docker daemon is not running"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Pipeline Manifest Schema Validation
# ------------------------------------------------------------------------------
log_step "Validating GitLab CI Manifest (.gitlab-ci.yml)"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    log_failure "Missing .gitlab-ci.yml at ${WORKFLOW_FILE}"
    exit 1
fi

if grep -q "deploy-staging:" "$WORKFLOW_FILE" && \
   grep -q "deploy-production:" "$WORKFLOW_FILE" && \
   grep -q "when: manual" "$WORKFLOW_FILE" && \
   grep -q "environment:" "$WORKFLOW_FILE"; then
    log_success "GitLab CI manifest defines valid stages, environments, and manual approval gates"
else
    log_failure "Invalid .gitlab-ci.yml schema or missing environment configurations"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Stage 1: Build & Static Code Quality
# ------------------------------------------------------------------------------
log_step "GitLab CI Stage 1: [build] - Compilation & Artifact Archival"

cd "$SCRIPT_DIR"

log_info "Executing: pnpm lint"
pnpm lint
log_success "ESLint static analysis passed with 0 errors"

log_info "Executing: pnpm build"
pnpm build

if [[ -f "${SCRIPT_DIR}/dist/server.js" ]]; then
    log_success "Compiled production distribution bundle (dist/server.js)"
else
    log_failure "Build failed: dist/server.js not found"
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Stage 2: Automated Testing
# ------------------------------------------------------------------------------
log_step "GitLab CI Stage 2: [test] - Automated Unit & Integration Tests"

log_info "Executing: pnpm test:coverage"
pnpm test:coverage
log_success "Unit test suite and code coverage verification passed"

# ------------------------------------------------------------------------------
# 5. Stage 3: Deploy to Staging (Continuous Deployment)
# ------------------------------------------------------------------------------
log_step "GitLab CI Stage 3: [deploy-staging] - Auto-Deploy to Staging"

log_info "Executing: ./deploy_mock.sh staging ${STAGING_PORT}"
"${SCRIPT_DIR}/deploy_mock.sh" staging "${STAGING_PORT}"

# Validate Staging Endpoint
STAGING_RESP=$(curl -s "http://127.0.0.1:${STAGING_PORT}/info")
if echo "$STAGING_RESP" | grep -q '"environment":"staging"'; then
    log_success "Staging environment is healthy and registered at http://127.0.0.1:${STAGING_PORT}"
else
    log_failure "Staging verification failed: ${STAGING_RESP}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Stage 4: Manual Production Gate & Deployment
# ------------------------------------------------------------------------------
if [[ "$SKIP_PROD" == "false" ]]; then
    log_step "GitLab CI Stage 4: [deploy-production] - Operator Manual Approval Gate"

    echo -e "${CLR_YELLOW}🔒 Manual Gate Triggered: Staging verified. Simulating Operator Approval...${CLR_RESET}"
    echo -e "${CLR_GREEN}✓ Operator Approved Production Release (Trigger: when: manual)${CLR_RESET}"

    log_info "Executing: ./deploy_mock.sh production ${PROD_PORT}"
    "${SCRIPT_DIR}/deploy_mock.sh" production "${PROD_PORT}"

    # Validate Production Endpoint
    PROD_RESP=$(curl -s "http://127.0.0.1:${PROD_PORT}/info")
    if echo "$PROD_RESP" | grep -q '"environment":"production"'; then
        log_success "Production environment is healthy and registered at http://127.0.0.1:${PROD_PORT}"
    else
        log_failure "Production verification failed: ${PROD_RESP}"
        exit 1
    fi
else
    log_info "Skipping Stage 4 (Production) per --no-prod flag."
fi

# ------------------------------------------------------------------------------
# 7. Summary Report & Environment URLs
# ------------------------------------------------------------------------------
log_header "📊 GitLab CI Multi-Environment Delivery Summary"

echo -e "${CLR_BOLD}Registered Environment URLs:${CLR_RESET}"
echo -e "  🌐 ${CLR_YELLOW}Staging Environment:    ${CLR_RESET} ${CLR_CYAN}http://127.0.0.1:${STAGING_PORT}${CLR_RESET} (Auto-Deployed)"
if [[ "$SKIP_PROD" == "false" ]]; then
    echo -e "  🚀 ${CLR_GREEN}Production Environment: ${CLR_RESET} ${CLR_CYAN}http://127.0.0.1:${PROD_PORT}${CLR_RESET} (Manual-Gated)"
fi

echo -e "\n${CLR_BOLD}Pipeline Stage Summary:${CLR_RESET}"
echo -e "  ${CLR_CYAN}Total Pipeline Steps: ${TOTAL_STEPS}${CLR_RESET}"
echo -e "  ${CLR_GREEN}Passed Steps:         ${PASSED_STEPS}${CLR_RESET}"
echo -e "  ${CLR_RED}Failed Steps:         ${FAILED_STEPS}${CLR_RESET}"

if [[ "$FAILED_STEPS" -eq 0 ]]; then
    echo -e "\n${CLR_BOLD}${CLR_GREEN}🎉 ALL GITLAB CI DELIVERY PIPELINE CHECKS PASSED SUCCESSFULLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_BOLD}${CLR_RED}❌ PIPELINE FAILED WITH ${FAILED_STEPS} ERRORS.${CLR_RESET}\n"
    exit 1
fi
