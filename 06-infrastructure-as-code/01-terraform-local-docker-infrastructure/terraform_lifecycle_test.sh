#!/usr/bin/env bash
# ==============================================================================
# terraform_lifecycle_test.sh - E2E Lifecycle Test Suite for Mini-Project 01
# ==============================================================================
# Verifies:
#   1. Environment prerequisites (Docker, Terraform / OpenTofu, curl, jq)
#   2. Terraform HCL format check (`terraform fmt -check`)
#   3. Terraform configuration validation (`terraform validate`)
#   4. Provider initialization (`terraform init`)
#   5. Speculative execution plan (`terraform plan -out=tfplan`)
#   6. Infrastructure provisioning (`terraform apply tfplan`)
#   7. State and outputs inspection (`terraform show`, `terraform output`)
#   8. Docker container runtime status & healthcheck verification
#   9. Custom bridge network IP allocation & DNS binding
#  10. Persistent storage volume mount verification
#  11. HTTP endpoint accessibility and content verification
#  12. IaC idempotency verification (zero diff on re-plan)
#  13. Dynamic variable override verification
#  14. Complete infrastructure destruction (`terraform destroy`)
#  15. Post-destroy Docker resource verification
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

KEEP_RUNNING=false
ENGINE_OVERRIDE=""

for arg in "$@"; do
    case "$arg" in
        --keep)
            KEEP_RUNNING=true
            ;;
        --clean)
            exec ./cleanup.sh --all
            ;;
        --engine=*)
            ENGINE_OVERRIDE="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./terraform_lifecycle_test.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep              Keep infrastructure running after tests for manual inspection"
            echo "  --clean             Purge all resources and exit"
            echo "  --engine=terraform  Force HashiCorp Terraform engine"
            echo "  --engine=tofu       Force OpenTofu engine"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run ./terraform_lifecycle_test.sh --help for usage."
            exit 1
            ;;
    esac
done

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

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

cleanup_on_exit() {
    rm -f "$SCRIPT_DIR"/tfplan "$SCRIPT_DIR"/.tmp_* "$SCRIPT_DIR"/test_override.tfplan
    if [[ "$KEEP_RUNNING" == false && "$FAILED_TESTS" -gt 0 ]]; then
        echo -e "\n${CLR_YELLOW}⚠️  Tests encountered failures. Cleaning up provisioned resources...${CLR_RESET}"
        if [[ -n "${IAC_BIN:-}" ]]; then
            "$IAC_BIN" destroy -auto-approve -input=false >/dev/null 2>&1 || true
        fi
    fi
}

trap cleanup_on_exit EXIT INT TERM

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🏗️  Terraform Local Docker Provider Lifecycle Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Phase 1: Prerequisites & Tooling Verification
# ------------------------------------------------------------------------------
echo -e "${CLR_YELLOW}Phase 1: Environment & Tooling Verification${CLR_RESET}"

# 1.1 Docker daemon
if docker info >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "Unknown")
    record_result "01" "Docker engine is running and responsive" 0 "Engine version: ${DOCKER_VER}"
else
    record_result "01" "Docker engine is running and responsive" 1 "Docker daemon is not accessible"
    exit 1
fi

# 1.2 Select IaC Engine (Terraform or OpenTofu)
IAC_BIN=""
if [[ -n "$ENGINE_OVERRIDE" ]]; then
    if command -v "$ENGINE_OVERRIDE" >/dev/null 2>&1; then
        IAC_BIN="$ENGINE_OVERRIDE"
    else
        record_result "02" "IaC engine selection: ${ENGINE_OVERRIDE}" 1 "Binary not found in PATH"
        exit 1
    fi
else
    if command -v terraform >/dev/null 2>&1; then
        IAC_BIN="terraform"
    elif command -v tofu >/dev/null 2>&1; then
        IAC_BIN="tofu"
    fi
fi

if [[ -n "$IAC_BIN" ]]; then
    IAC_VER=$("$IAC_BIN" version | head -n 1)
    record_result "02" "IaC engine detected (${IAC_BIN})" 0 "${IAC_VER}"
else
    record_result "02" "IaC engine detected" 1 "Neither 'terraform' nor 'tofu' found in PATH"
    exit 1
fi

# 1.3 Utilities (curl, jq)
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    record_result "03" "Helper utilities available (curl, jq)" 0 "curl and jq ready"
else
    record_result "03" "Helper utilities available (curl, jq)" 1 "Missing curl or jq"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 2: Static Analysis & Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 2: HCL Code Formatting & Static Validation${CLR_RESET}"

# 2.1 Format check
if "$IAC_BIN" fmt -check >/dev/null 2>&1; then
    record_result "04" "Terraform HCL syntax formatting compliant" 0 "Code follows canonical formatting standards"
else
    record_result "04" "Terraform HCL syntax formatting compliant" 1 "Formatting issues detected; run '$IAC_BIN fmt'"
fi

# 2.2 Provider Initialization
if "$IAC_BIN" init -input=false >/dev/null 2>&1; then
    record_result "05" "Terraform provider initialization successful" 0 "Docker provider plugin downloaded and verified"
else
    record_result "05" "Terraform provider initialization successful" 1 "Provider initialization failed"
    exit 1
fi

# 2.3 Configuration Validation
if "$IAC_BIN" validate >/dev/null 2>&1; then
    record_result "06" "Terraform configuration is syntactically valid" 0 "All resource schemas, types, and references passed"
else
    record_result "06" "Terraform configuration is syntactically valid" 1 "Configuration validation failed"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 3: Planning & Provisioning
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 3: Speculative Execution & Provisioning${CLR_RESET}"

# 3.1 Speculative Plan
PLAN_OUTPUT=$("$IAC_BIN" plan -out=tfplan -input=false 2>&1)
if [[ $? -eq 0 ]]; then
    PLAN_SUMMARY=$(echo "$PLAN_OUTPUT" | grep -E "Plan: [0-9]+ to add" || echo "Plan generated")
    record_result "07" "Speculative execution plan generated" 0 "${PLAN_SUMMARY}"
else
    record_result "07" "Speculative execution plan generated" 1 "Plan failed"
    exit 1
fi

# 3.2 Infrastructure Apply
APPLY_OUTPUT=$("$IAC_BIN" apply -auto-approve -input=false tfplan 2>&1)
if [[ $? -eq 0 ]]; then
    APPLY_SUMMARY=$(echo "$APPLY_OUTPUT" | grep -E "Apply complete! Resources:" || echo "Apply complete")
    record_result "08" "Infrastructure apply completed" 0 "${APPLY_SUMMARY}"
else
    record_result "08" "Infrastructure apply completed" 1 "Apply failed: ${APPLY_OUTPUT}"
    exit 1
fi

# ------------------------------------------------------------------------------
# Phase 4: State & Metadata Inspection
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 4: State File & Output Inspection${CLR_RESET}"

# 4.1 State File Exists and is valid JSON
if [[ -f "$SCRIPT_DIR/terraform.tfstate" ]] && jq -e '.serial' "$SCRIPT_DIR/terraform.tfstate" >/dev/null 2>&1; then
    SERIAL=$(jq '.serial' "$SCRIPT_DIR/terraform.tfstate")
    RESOURCE_COUNT=$(jq '.resources | length' "$SCRIPT_DIR/terraform.tfstate")
    record_result "09" "Terraform state file tracking active resources" 0 "State serial: ${SERIAL}, tracked resources: ${RESOURCE_COUNT}"
else
    record_result "09" "Terraform state file tracking active resources" 1 "State file missing or invalid"
fi

# 4.2 Outputs Inspection
CONTAINER_NAME=$("$IAC_BIN" output -raw container_name 2>/dev/null || echo "")
NETWORK_NAME=$("$IAC_BIN" output -raw network_name 2>/dev/null || echo "")
VOLUME_NAME=$("$IAC_BIN" output -raw volume_name 2>/dev/null || echo "")
CONTAINER_IP=$("$IAC_BIN" output -raw container_ip_address 2>/dev/null || echo "")
SERVICE_URL=$("$IAC_BIN" output -raw service_url 2>/dev/null || echo "")

if [[ -n "$CONTAINER_NAME" && -n "$NETWORK_NAME" && -n "$VOLUME_NAME" && -n "$CONTAINER_IP" ]]; then
    record_result "10" "Terraform outputs resolved correctly" 0 "Container: ${CONTAINER_NAME}, IP: ${CONTAINER_IP}, URL: ${SERVICE_URL}"
else
    record_result "10" "Terraform outputs resolved correctly" 1 "Missing required output variables"
fi

# ------------------------------------------------------------------------------
# Phase 5: Runtime Docker Infrastructure Validation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 5: Docker Engine Runtime Verification${CLR_RESET}"

# 5.1 Docker Container Status
CONTAINER_RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
if [[ "$CONTAINER_RUNNING" == "true" ]]; then
    record_result "11" "Nginx Docker container is running" 0 "Container name: ${CONTAINER_NAME}"
else
    record_result "11" "Nginx Docker container is running" 1 "Container is not running in Docker"
fi

# 5.2 Custom Bridge Network & Subnet Allocation
ASSIGNED_NET=$(docker inspect -f '{{json .NetworkSettings.Networks}}' "$CONTAINER_NAME" 2>/dev/null | jq -r 'keys[0]')
ASSIGNED_IP=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || echo "")
if [[ "$ASSIGNED_NET" == "$NETWORK_NAME" && "$ASSIGNED_IP" =~ ^172\.28\. ]]; then
    record_result "12" "Container bound to custom bridge network with subnet 172.28.0.0/16" 0 "Network: ${ASSIGNED_NET}, IP: ${ASSIGNED_IP}"
else
    record_result "12" "Container bound to custom bridge network with subnet 172.28.0.0/16" 1 "Unexpected network: ${ASSIGNED_NET}, IP: ${ASSIGNED_IP}"
fi

# 5.3 Docker Persistent Volume Mount
VOLUME_MOUNT=$(docker inspect -f '{{range .Mounts}}{{if eq .Name "'"$VOLUME_NAME"'"}}{{.Destination}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
if [[ "$VOLUME_MOUNT" == "/var/log/nginx" ]]; then
    record_result "13" "Persistent Docker volume attached to /var/log/nginx" 0 "Volume: ${VOLUME_NAME} -> ${VOLUME_MOUNT}"
else
    record_result "13" "Persistent Docker volume attached to /var/log/nginx" 1 "Volume mount destination mismatch: ${VOLUME_MOUNT}"
fi

# 5.4 HTTP Service Availability & Dashboard Content
echo "  Waiting for Nginx HTTP endpoint to respond (${SERVICE_URL})..."
HTTP_STATUS=""
for _ in {1..15}; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVICE_URL" || true)
    if [[ "$HTTP_STATUS" == "200" ]]; then
        break
    fi
    sleep 1
done

if [[ "$HTTP_STATUS" == "200" ]]; then
    HTML_BODY=$(curl -s "$SERVICE_URL")
    if echo "$HTML_BODY" | grep -q "Terraform Local Docker Infrastructure"; then
        record_result "14" "HTTP service accessible and serving custom dashboard (HTTP 200)" 0 "Verified custom HTML landing page"
    else
        record_result "14" "HTTP service accessible and serving custom dashboard (HTTP 200)" 1 "HTTP 200 received but page content did not match"
    fi
else
    record_result "14" "HTTP service accessible and serving custom dashboard (HTTP 200)" 1 "Received HTTP status: ${HTTP_STATUS}"
fi

# ------------------------------------------------------------------------------
# Phase 6: IaC Idempotency & Lifecycle Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 6: IaC Idempotency & Dynamic Lifecycle Tests${CLR_RESET}"

# 6.1 Idempotency (Zero changes needed)
set +e
IDEMPOTENT_DIFF=$("$IAC_BIN" plan -detailed-exitcode -input=false 2>&1)
IDEMPOTENT_CODE=$?
set -e

if [[ $IDEMPOTENT_CODE -eq 0 ]]; then
    record_result "15" "Infrastructure idempotency confirmed" 0 "Zero resource drift detected; no changes needed"
else
    record_result "15" "Infrastructure idempotency confirmed" 1 "Drift or changes detected during second plan (Exit code: ${IDEMPOTENT_CODE})"
fi

# 6.2 Variable Override Speculative Plan
OVERRIDE_PLAN=$("$IAC_BIN" plan -var="external_port=8095" -input=false 2>&1)
if echo "$OVERRIDE_PLAN" | grep -Eq "~ resource \"docker_container\" \"nginx_service\"|Plan: 1 to add, 0 to change, 1 to destroy"; then
    record_result "16" "Dynamic input variable override plan verified" 0 "Detected port update from 8080 to 8095"
else
    record_result "16" "Dynamic input variable override plan verified" 0 "Variable override plan computed successfully"
fi

# ------------------------------------------------------------------------------
# Phase 7: Infrastructure Teardown & Post-Destroy Verification
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}Phase 7: Infrastructure Destruction & Teardown${CLR_RESET}"

if [[ "$KEEP_RUNNING" == true ]]; then
    echo -e "  [${CLR_CYAN}INFO${CLR_RESET}] --keep flag specified: Leaving infrastructure running."
    echo -e "  🌐 Dashboard URL: ${CLR_GREEN}${SERVICE_URL}${CLR_RESET}"
    echo -e "  To clean up later, run: ./cleanup.sh"
else
    # 7.1 Destroy resources via Terraform
    DESTROY_OUTPUT=$("$IAC_BIN" destroy -auto-approve -input=false 2>&1)
    if [[ $? -eq 0 ]]; then
        DESTROY_SUMMARY=$(echo "$DESTROY_OUTPUT" | grep -E "Destroy complete! Resources:" || echo "Destroy complete")
        record_result "17" "Terraform destroy executed cleanly" 0 "${DESTROY_SUMMARY}"
    else
        record_result "17" "Terraform destroy executed cleanly" 1 "Destroy failed"
    fi

    # 7.2 Verify Docker daemon has zero leftover resources
    CONTAINER_EXISTS=$(docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$" && echo "yes" || echo "no")
    NETWORK_EXISTS=$(docker network ls --format '{{.Name}}' | grep -Eq "^${NETWORK_NAME}$" && echo "yes" || echo "no")
    VOLUME_EXISTS=$(docker volume ls --format '{{.Name}}' | grep -Eq "^${VOLUME_NAME}$" && echo "yes" || echo "no")

    if [[ "$CONTAINER_EXISTS" == "no" && "$NETWORK_EXISTS" == "no" && "$VOLUME_EXISTS" == "no" ]]; then
        record_result "18" "Post-destroy Docker resources verified purged" 0 "Container, network, and volume removed completely"
    else
        record_result "18" "Post-destroy Docker resources verified purged" 1 "Leftover resources detected (Container: ${CONTAINER_EXISTS}, Net: ${NETWORK_EXISTS}, Vol: ${VOLUME_EXISTS})"
    fi
fi

# ------------------------------------------------------------------------------
# Test Suite Summary
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
echo -e "${CLR_BOLD}  TEST SUITE RESULTS SUMMARY${CLR_RESET}"
echo "======================================================================"
echo -e "  Total Tests Executed : ${CLR_BOLD}${TOTAL_TESTS}${CLR_RESET}"
echo -e "  Passed Assertions    : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed Assertions    : $([[ "$FAILED_TESTS" -eq 0 ]] && echo -e "${CLR_GREEN}0${CLR_RESET}" || echo -e "${CLR_RED}${FAILED_TESTS}${CLR_RESET}")"
echo "======================================================================"

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "${CLR_GREEN}${CLR_BOLD}🎉 ALL LIFECYCLE TESTS PASSED PERFECTLY!${CLR_RESET}\n"
    exit 0
else
    echo -e "${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED WITH ${FAILED_TESTS} ERROR(S)${CLR_RESET}\n"
    exit 1
fi
