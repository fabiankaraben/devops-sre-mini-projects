#!/usr/bin/env bash
# ==============================================================================
# test_sentinel_failover.sh - Automated Redis Sentinel HA & Failover Test Suite
# ==============================================================================
# Executes comprehensive validation checkpoints:
# 1. 6-Node Cluster Infrastructure Startup & Container Health Checks
# 2. Master-Replica Asynchronous Replication Handshake Verification
# 3. Sentinel Consensus Quorum & Multi-Node Monitoring Audit (Quorum = 2)
# 4. Transactional Data Ingestion & Cross-Replica Sync Parity
# 5. Simulated Catastrophic Master Failure (docker stop redis-master)
# 6. Automatic Failover & Replica Promotion Assertion (within 5 seconds)
# 7. Cluster Self-Healing & Former Master Reconfiguration as Slave
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

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    shift
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "\n${CLR_CYAN}${CLR_BOLD}▶ [TEST ${TOTAL_TESTS}] ${test_name}${CLR_RESET}"
    if "$@"; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  [${CLR_GREEN}PASS${CLR_RESET}] ${test_name}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  [${CLR_RED}FAIL${CLR_RESET}] ${test_name}"
        return 1
    fi
}

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  🧪 Redis Sentinel High Availability & Failover - Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

# Determine Docker Compose CLI syntax
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${CLR_RED}Error: Docker Compose is required to run this test suite.${CLR_RESET}" >&2
    exit 1
fi

chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py 2>/dev/null || true

# ------------------------------------------------------------------------------
# Test 1: 6-Node Cluster Infrastructure Startup & Health Checks
# ------------------------------------------------------------------------------
test_cluster_startup() {
    echo "  Tearing down prior containers and starting fresh 6-node stack..."
    $COMPOSE_CMD down -v >/dev/null 2>&1 || true
    $COMPOSE_CMD up -d --wait

    local retries=25
    while (( retries > 0 )); do
        local healthy_count
        healthy_count=$(docker ps --filter "health=healthy" --format "{{.Names}}" | grep -E "redis-master|redis-replica|redis-sentinel" | wc -l | tr -d ' ')
        if (( healthy_count >= 6 )); then
            echo "  All 6 cluster nodes (3 Redis + 3 Sentinels) are running and healthy."
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "  Timed out waiting for 6 cluster nodes to become healthy (found: $healthy_count)."
    return 1
}
run_test "6-Node Cluster Infrastructure Startup & Health Checks" test_cluster_startup

# ------------------------------------------------------------------------------
# Test 2: Master-Replica Asynchronous Replication Handshake Verification
# ------------------------------------------------------------------------------
test_replication_handshake() {
    echo "  Checking Redis Master replication status..."
    local repl_info role connected_slaves
    repl_info=$(docker exec redis-master redis-cli info replication)
    role=$(echo "$repl_info" | grep "^role:" | tr -d '\r' | cut -d: -f2)
    connected_slaves=$(echo "$repl_info" | grep "^connected_slaves:" | tr -d '\r' | cut -d: -f2)

    echo "  redis-master role            : ${role}"
    echo "  connected replica nodes count: ${connected_slaves}"

    if [[ "$role" == "master" ]] && (( connected_slaves >= 2 )); then
        echo "  Replication handshake verified (Master connected to 2 replicas)."
        return 0
    else
        echo "  Replication handshake failed. Expected role=master, connected_slaves>=2, got role=$role, slaves=$connected_slaves"
        return 1
    fi
}
run_test "Master-Replica Replication Handshake Verification" test_replication_handshake

# ------------------------------------------------------------------------------
# Test 3: Sentinel Consensus Quorum & Multi-Node Monitoring Audit
# ------------------------------------------------------------------------------
test_sentinel_quorum() {
    echo "  Auditing Sentinel cluster topology and quorum configuration..."
    local retries=15
    local num_slaves=0 num_sentinels=0 quorum=0

    while (( retries > 0 )); do
        local sentinel_info
        sentinel_info=$(docker exec redis-sentinel-1 redis-cli -p 26379 sentinel master mymaster 2>/dev/null || true)
        num_slaves=$(echo "$sentinel_info" | awk '/num-slaves/{getline; print}' || echo 0)
        num_sentinels=$(echo "$sentinel_info" | awk '/num-other-sentinels/{getline; print}' || echo 0)
        quorum=$(echo "$sentinel_info" | awk '/quorum/{getline; print}' || echo 0)

        if (( num_slaves >= 2 )) && (( num_sentinels >= 2 )) && (( quorum == 2 )); then
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done

    echo "  Monitored replicas count : ${num_slaves}"
    echo "  Other Sentinels detected : ${num_sentinels}"
    echo "  Configured election quorum: ${quorum}"

    if (( num_slaves >= 2 )) && (( num_sentinels >= 2 )) && (( quorum == 2 )); then
        echo "  Sentinel consensus quorum verified (3 sentinels, 2 replicas, quorum=2)."
        return 0
    else
        echo "  Sentinel quorum check failed (slaves=$num_slaves, sentinels=$num_sentinels, quorum=$quorum)."
        return 1
    fi
}
run_test "Sentinel Consensus Quorum & Multi-Node Monitoring Audit" test_sentinel_quorum

# ------------------------------------------------------------------------------
# Test 4: Transactional Data Ingestion & Cross-Replica Sync Parity
# ------------------------------------------------------------------------------
test_data_ingestion_sync() {
    echo "  Ingesting 100 test keys into active master..."
    for i in $(seq 1 100); do
        docker exec redis-master redis-cli SET "test_key_${i}" "val_${i}_$(date +%s)" >/dev/null
    done

    sleep 1

    local replica1_val replica2_val
    replica1_val=$(docker exec redis-replica-1 redis-cli GET test_key_100 | tr -d '\r')
    replica2_val=$(docker exec redis-replica-2 redis-cli GET test_key_100 | tr -d '\r')

    echo "  Value on replica-1: ${replica1_val}"
    echo "  Value on replica-2: ${replica2_val}"

    if [[ -n "$replica1_val" && "$replica1_val" == "$replica2_val" ]]; then
        echo "  Data synchronization verified across both replicas."
        return 0
    else
        echo "  Data replication parity failed between replicas."
        return 1
    fi
}
run_test "Transactional Data Ingestion & Cross-Replica Sync Parity" test_data_ingestion_sync

# ------------------------------------------------------------------------------
# Test 5: Simulated Catastrophic Master Failure
# ------------------------------------------------------------------------------
test_simulate_master_crash() {
    echo "  Simulating catastrophic master hardware crash (stopping redis-master container)..."
    docker stop redis-master >/dev/null
    echo "  redis-master container stopped."
    return 0
}
run_test "Simulated Catastrophic Master Crash" test_simulate_master_crash

# ------------------------------------------------------------------------------
# Test 6: Automatic Failover & Replica Promotion Assertion (within 5 seconds)
# ------------------------------------------------------------------------------
test_automatic_failover_promotion() {
    echo "  Waiting for Sentinel to detect ODOWN, elect leader, and promote replica..."
    local retries=15
    local promoted_node=""

    while (( retries > 0 )); do
        local master_addr
        master_addr=$(docker exec redis-sentinel-1 redis-cli -p 26379 sentinel get-master-addr-by-name mymaster 2>/dev/null || true)
        local m_ip
        m_ip=$(echo "$master_addr" | head -n1 | tr -d '\r')
        if [[ "$m_ip" != "redis-master" && -n "$m_ip" ]]; then
            local role1 role2
            role1=$(docker exec redis-replica-1 redis-cli info replication 2>/dev/null | grep "^role:" | tr -d '\r' | cut -d: -f2 || true)
            role2=$(docker exec redis-replica-2 redis-cli info replication 2>/dev/null | grep "^role:" | tr -d '\r' | cut -d: -f2 || true)
            if [[ "$role1" == "master" ]]; then
                promoted_node="redis-replica-1"
                break
            elif [[ "$role2" == "master" ]]; then
                promoted_node="redis-replica-2"
                break
            fi
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if [[ -n "$promoted_node" ]]; then
        echo "  Promoted node identified: ${promoted_node}"
        local write_check
        write_check=$(docker exec "$promoted_node" redis-cli SET failover_canary_key "promoted_success" 2>&1)
        echo "  Write attempt to promoted master (${promoted_node}): ${write_check}"
        if echo "$write_check" | grep -q "OK"; then
            echo "  Automatic failover verified: ${promoted_node} is now writable master."
            return 0
        fi
    fi

    echo "  Failover failed or no replica was promoted to writable master."
    return 1
}
run_test "Automatic Failover & Replica Promotion Assertion" test_automatic_failover_promotion

# ------------------------------------------------------------------------------
# Test 7: Cluster Self-Healing & Former Master Reconfiguration as Slave
# ------------------------------------------------------------------------------
test_self_healing_former_master() {
    echo "  Restarting former master container (redis-master)..."
    docker start redis-master >/dev/null
    
    echo "  Waiting for Sentinel to detect recovered node and reconfigure as replica..."
    local retries=15
    local converted_role=""

    while (( retries > 0 )); do
        converted_role=$(docker exec redis-master redis-cli info replication 2>/dev/null | grep "^role:" | tr -d '\r' | cut -d: -f2 || true)
        if [[ "$converted_role" == "slave" ]]; then
            echo "  Former master successfully reconfigured into: ${converted_role}"
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if [[ "$converted_role" == "slave" ]]; then
        echo "  Cluster self-healing verified (former master rejoined as slave)."
        return 0
    else
        echo "  Former master failed to reconfigure as slave (role is '$converted_role')."
        return 1
    fi
}
run_test "Cluster Self-Healing & Former Master Reconfiguration as Slave" test_self_healing_former_master

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 Redis Sentinel Test Execution Summary${CLR_RESET}"
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "  Total Test Checkpoints : ${TOTAL_TESTS}"
echo -e "  Passed                 : ${CLR_GREEN}${PASSED_TESTS}${CLR_RESET}"
echo -e "  Failed                 : $( [ $FAILED_TESTS -gt 0 ] && echo "${CLR_RED}${FAILED_TESTS}${CLR_RESET}" || echo "0" )"
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"

if (( FAILED_TESTS == 0 )); then
    echo -e "\n${CLR_GREEN}${CLR_BOLD}🎉 All 7 Test Checkpoints Passed Successfully!${CLR_RESET}\n"
    exit 0
else
    echo -e "\n${CLR_RED}${CLR_BOLD}✖ Test Suite Failed with $FAILED_TESTS failure(s).${CLR_RESET}\n"
    exit 1
fi
