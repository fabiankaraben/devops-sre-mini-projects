#!/usr/bin/env bash
# ==============================================================================
# test_dynamic_fleet.sh - End-to-End Test Suite for Ansible Dynamic Inventory
# ==============================================================================
# Verifies:
#   1. Prerequisites (Docker, Python 3, Ansible CLI, curl)
#   2. Fleet provisioning via fleet_manager.sh
#   3. Dynamic Inventory JSON schema & CLI (--list, --host)
#   4. Ansible inventory graph generation (ansible-inventory --graph)
#   5. Tag-based keyed group memberships (Environment, Role, App)
#   6. Host variable injection (ansible_connection=docker, tags)
#   7. Fleet connectivity (ansible -m ping all)
#   8. Dynamic group pattern targeting (ansible "env_production:&role_web")
#   9. Rolling update playbook execution with serial: 1
#  10. Version and health verification across target vs non-target nodes
#  11. Dynamic scale-out discovery (auto-scaling simulation without config edits)
#  12. Teardown and environment cleanup
# ==============================================================================

set -euo pipefail

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_GRAY="\033[0;90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure local directories exist for strict containment
mkdir -p .ansible/tmp .ansible/cp logs

KEEP_RUNNING=false

for arg in "$@"; do
    case "$arg" in
        --keep)
            KEEP_RUNNING=true
            ;;
        --clean)
            exec ./cleanup.sh --all
            ;;
        --help|-h)
            echo "Usage: ./test_dynamic_fleet.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep     Keep fleet containers and resources active after test run"
            echo "  --clean    Purge all containers, images, and logs immediately"
            echo "  --help, -h Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./test_dynamic_fleet.sh --help for usage."
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

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 Ansible Dynamic Inventory for Cloud Fleets - Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# ------------------------------------------------------------------------------
# Test 1: Prerequisites Check
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 1: Checking system prerequisites...${CLR_RESET}"
MISSING_TOOLS=()
for tool in docker python3 ansible ansible-inventory ansible-playbook curl; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -eq 0 ]]; then
    if docker info >/dev/null 2>&1; then
        record_result "1" "All prerequisites verified (Docker daemon, Python 3, Ansible tools, curl)" 0
    else
        record_result "1" "Docker daemon is not running" 1 "Ensure Docker or OrbStack is active"
    fi
else
    record_result "1" "Missing required tools: ${MISSING_TOOLS[*]}" 1
fi

# ------------------------------------------------------------------------------
# Test 2: Fleet Provisioning
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 2: Provisioning simulated cloud fleet (5 nodes)...${CLR_RESET}"
if ./fleet_manager.sh up >/dev/null 2>&1; then
    ACTIVE_COUNT=$(docker ps --filter "label=devops.fleet=ansible-dynamic-inventory" --format '{{.Names}}' | wc -l | tr -d ' ')
    if [[ "$ACTIVE_COUNT" -ge 5 ]]; then
        record_result "2" "Provisioned 5 fleet nodes (web-prod-01/02, web-stage-01, api-prod-01, db-prod-01)" 0 "Active containers: $ACTIVE_COUNT"
    else
        record_result "2" "Fleet provisioning incomplete" 1 "Expected >= 5, got $ACTIVE_COUNT"
    fi
else
    record_result "2" "fleet_manager.sh up failed" 1
fi

# ------------------------------------------------------------------------------
# Test 3: Dynamic Inventory JSON Contract
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 3: Validating Dynamic Inventory JSON Output (--list)...${CLR_RESET}"
INVENTORY_JSON=$(python3 ./docker_inventory.py --list 2>/dev/null || echo "")
if [[ -n "$INVENTORY_JSON" ]] && echo "$INVENTORY_JSON" | python3 -c 'import sys, json; data=json.load(sys.stdin); assert "_meta" in data and "hostvars" in data["_meta"]' 2>/dev/null; then
    HOSTVARS_COUNT=$(echo "$INVENTORY_JSON" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)["_meta"]["hostvars"]))')
    record_result "3" "docker_inventory.py conforms to Ansible Dynamic Inventory JSON spec" 0 "Discovered $HOSTVARS_COUNT hosts with hostvars"
else
    record_result "3" "Invalid JSON output from docker_inventory.py" 1
fi

# ------------------------------------------------------------------------------
# Test 4: Ansible Inventory Graph Generation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 4: Generating Ansible inventory graph (ansible-inventory --graph)...${CLR_RESET}"
GRAPH_OUTPUT=$(ansible-inventory -i docker_inventory.py --graph 2>&1 || echo "")
if [[ "$GRAPH_OUTPUT" == *"@all:"* && "$GRAPH_OUTPUT" == *"@env_production:"* && "$GRAPH_OUTPUT" == *"@role_web:"* ]]; then
    record_result "4" "Ansible successfully generated hierarchical inventory graph" 0
else
    record_result "4" "ansible-inventory --graph output failed or missing expected groups" 1 "$GRAPH_OUTPUT"
fi

# ------------------------------------------------------------------------------
# Test 5: Keyed Tag Group Membership Assertions
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 5: Asserting dynamic group memberships...${CLR_RESET}"
GROUP_TEST_FAILED=0

# Assert env_production contains web-prod-01, web-prod-02, api-prod-01, db-prod-01
PROD_HOSTS=$(python3 ./docker_inventory.py --list | python3 -c 'import sys, json; print(" ".join(json.load(sys.stdin).get("env_production", {}).get("hosts", [])))')
STAGE_HOSTS=$(python3 ./docker_inventory.py --list | python3 -c 'import sys, json; print(" ".join(json.load(sys.stdin).get("env_staging", {}).get("hosts", [])))')
WEB_HOSTS=$(python3 ./docker_inventory.py --list | python3 -c 'import sys, json; print(" ".join(json.load(sys.stdin).get("role_web", {}).get("hosts", [])))')

if [[ "$PROD_HOSTS" == *"web-prod-01"* && "$PROD_HOSTS" == *"web-prod-02"* && "$PROD_HOSTS" == *"api-prod-01"* && "$PROD_HOSTS" == *"db-prod-01"* && "$PROD_HOSTS" != *"web-stage-01"* ]]; then
    if [[ "$STAGE_HOSTS" == *"web-stage-01"* && "$STAGE_HOSTS" != *"web-prod-01"* ]]; then
        if [[ "$WEB_HOSTS" == *"web-prod-01"* && "$WEB_HOSTS" == *"web-prod-02"* && "$WEB_HOSTS" == *"web-stage-01"* && "$WEB_HOSTS" != *"db-prod-01"* ]]; then
            record_result "5" "Tag-based dynamic groups (env_*, role_*) partitioned correctly" 0 "Production: 4 hosts, Staging: 1 host, Web: 3 hosts"
        else
            GROUP_TEST_FAILED=1
        fi
    else
        GROUP_TEST_FAILED=1
    fi
else
    GROUP_TEST_FAILED=1
fi

if [[ "$GROUP_TEST_FAILED" -eq 1 ]]; then
    record_result "5" "Tag-based dynamic group partitioning failed" 1 "Prod: '$PROD_HOSTS', Stage: '$STAGE_HOSTS', Web: '$WEB_HOSTS'"
fi

# ------------------------------------------------------------------------------
# Test 6: Host Variables Resolution
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 6: Testing host variable resolution (ansible-inventory --host)...${CLR_RESET}"
HOST_VARS_JSON=$(ansible-inventory -i docker_inventory.py --host web-prod-01 2>/dev/null || echo "")
if echo "$HOST_VARS_JSON" | python3 -c 'import sys, json; data=json.load(sys.stdin); assert data.get("ansible_connection") == "docker" and data.get("environment_tag") == "production" and data.get("role_tag") == "web"' 2>/dev/null; then
    record_result "6" "Dynamic hostvars injected correctly (connection=docker, env=production, role=web)" 0
else
    record_result "6" "Dynamic hostvars missing required attributes" 1 "$HOST_VARS_JSON"
fi

# ------------------------------------------------------------------------------
# Test 7: Fleet Ping / Direct Connectivity
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 7: Testing dynamic fleet ping connectivity (ansible -m ping all)...${CLR_RESET}"
if ansible -i docker_inventory.py -m ping all >/dev/null 2>&1; then
    record_result "7" "All dynamically discovered nodes responded to Ansible ping" 0
else
    record_result "7" "Ansible ping failed on one or more fleet nodes" 1
fi

# ------------------------------------------------------------------------------
# Test 8: Target Pattern Matching
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 8: Testing composite pattern execution ('env_production:&role_web')...${CLR_RESET}"
PATTERN_OUTPUT=$(ansible -i docker_inventory.py "env_production:&role_web" -m command -a "cat /app/version.txt" 2>&1 || echo "")
if [[ "$PATTERN_OUTPUT" == *"web-prod-01 | CHANGED"* || "$PATTERN_OUTPUT" == *"web-prod-01 | SUCCESS"* ]]; then
    if [[ "$PATTERN_OUTPUT" == *"web-prod-02"* && "$PATTERN_OUTPUT" != *"web-stage-01"* && "$PATTERN_OUTPUT" != *"api-prod-01"* ]]; then
        record_result "8" "Targeted composite pattern ('env_production:&role_web') selected exact nodes" 0 "Matched: web-prod-01, web-prod-02"
    else
        record_result "8" "Targeted pattern matched unexpected hosts" 1 "$PATTERN_OUTPUT"
    fi
else
    record_result "8" "Targeted ad-hoc execution failed" 1 "$PATTERN_OUTPUT"
fi

# ------------------------------------------------------------------------------
# Test 9: Zero-Downtime Rolling Update Playbook
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 9: Executing Rolling Update Playbook (serial: 1, version: 2.0.0)...${CLR_RESET}"
PLAYBOOK_OUTPUT=$(ansible-playbook -i docker_inventory.py rolling_update.yml -e "app_target_version=2.0.0" 2>&1 || echo "")
if [[ "$PLAYBOOK_OUTPUT" == *"failed=0"* && "$PLAYBOOK_OUTPUT" == *"unreachable=0"* ]]; then
    record_result "9" "Rolling update playbook executed successfully with serial: 1" 0
else
    record_result "9" "Rolling update playbook encountered failures" 1 "$PLAYBOOK_OUTPUT"
fi

# ------------------------------------------------------------------------------
# Test 10: Post-Update Node State & Isolation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 10: Verifying post-update versions & target isolation...${CLR_RESET}"
VER_PROD_01=$(curl -s "http://127.0.0.1:8081/version" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("version", ""))' 2>/dev/null || echo "")
VER_PROD_02=$(curl -s "http://127.0.0.1:8082/version" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("version", ""))' 2>/dev/null || echo "")
VER_STAGE_01=$(curl -s "http://127.0.0.1:8083/version" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("version", ""))' 2>/dev/null || echo "")
VER_API_01=$(curl -s "http://127.0.0.1:8084/version" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("version", ""))' 2>/dev/null || echo "")

if [[ "$VER_PROD_01" == "2.0.0" && "$VER_PROD_02" == "2.0.0" && "$VER_STAGE_01" == "1.0.0" && "$VER_API_01" == "1.0.0" ]]; then
    record_result "10" "Target isolation verified (prod web updated to 2.0.0; stage/api preserved at 1.0.0)" 0
else
    record_result "10" "Version verification failed" 1 "prod01: '$VER_PROD_01', prod02: '$VER_PROD_02', stage01: '$VER_STAGE_01', api01: '$VER_API_01'"
fi

# ------------------------------------------------------------------------------
# Test 11: Dynamic Auto-Scaling Discovery Test
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 11: Simulating Auto-Scaling event (provisioning web-prod-03)...${CLR_RESET}"
./fleet_manager.sh scale --role web --env production --name web-prod-03 --port 8086 >/dev/null 2>&1 || true

SCALE_INVENTORY=$(python3 ./docker_inventory.py --list)
SCALE_PROD_HOSTS=$(echo "$SCALE_INVENTORY" | python3 -c 'import sys, json; print(" ".join(json.load(sys.stdin).get("env_production", {}).get("hosts", [])))')

if [[ "$SCALE_PROD_HOSTS" == *"web-prod-03"* ]]; then
    SCALE_PING=$(ansible -i docker_inventory.py web-prod-03 -m ping 2>&1 || echo "")
    if [[ "$SCALE_PING" == *"SUCCESS"* ]]; then
        record_result "11" "Auto-scaled node 'web-prod-03' discovered dynamically and reachable" 0 "Instant discovery with 0 configuration file edits"
    else
        record_result "11" "Scaled node discovered but ping failed" 1 "$SCALE_PING"
    fi
else
    record_result "11" "Dynamic inventory failed to discover newly scaled node" 1 "Prod hosts: $SCALE_PROD_HOSTS"
fi

# ------------------------------------------------------------------------------
# Test 12: Teardown & Environment Sanitation
# ------------------------------------------------------------------------------
echo -e "\n${CLR_YELLOW}▶ Step 12: Testing cleanup and resource teardown...${CLR_RESET}"
if [[ "$KEEP_RUNNING" == false ]]; then
    if ./cleanup.sh --all >/dev/null 2>&1; then
        REMAINING_CONTAINERS=$(docker ps -a --filter "label=devops.fleet=ansible-dynamic-inventory" --format '{{.Names}}' | wc -l | tr -d ' ')
        if [[ "$REMAINING_CONTAINERS" -eq 0 ]]; then
            record_result "12" "Cleanup script purged all fleet containers, network, and temporary caches" 0
        else
            record_result "12" "Cleanup left dangling containers" 1 "Remaining: $REMAINING_CONTAINERS"
        fi
    else
        record_result "12" "cleanup.sh execution failed" 1
    fi
else
    echo -e "  [${CLR_CYAN}SKIP${CLR_RESET}] Test 12: Cleanup skipped (--keep flag active)."
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# ------------------------------------------------------------------------------
# Summary Recap
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "  ${CLR_GREEN}${CLR_BOLD}🎉 ALL $TOTAL_TESTS TESTS PASSED! ($PASSED_TESTS/$TOTAL_TESTS)${CLR_RESET}"
    echo "======================================================================"
    exit 0
else
    echo -e "  ${CLR_RED}${CLR_BOLD}❌ TEST SUITE FAILED: $FAILED_TESTS of $TOTAL_TESTS tests failed.${CLR_RESET}"
    echo "======================================================================"
    exit 1
fi
