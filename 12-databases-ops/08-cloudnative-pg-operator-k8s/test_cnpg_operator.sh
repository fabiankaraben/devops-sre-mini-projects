#!/usr/bin/env bash
# ==============================================================================
# test_cnpg_operator.sh - Automated CloudNative-PG Operator Test Suite
# ==============================================================================
# Executes comprehensive Kubernetes database validation checkpoints:
# 1. Local Kubernetes Cluster & CloudNative-PG Operator Controller Readiness
# 2. MinIO S3 Object Storage & Backup Bucket Setup
# 3. 3-Instance PostgreSQL Cluster CRD Creation & Healthy State Check
# 4. Initial Schema & Seed Data Ingestion on Primary
# 5. Standby Streaming Replication Audit (pg_stat_replication)
# 6. Primary Termination & Automated Standby Promotion (RTO < 10s, 0 data loss)
# 7. S3 Physical Backup CRD Execution & WAL Archiving Verification
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
echo "  🧪 CloudNative-PG Operator on Kubernetes - Automated Test Suite"
echo "======================================================================"
echo -e "${CLR_RESET}"

chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

# ------------------------------------------------------------------------------
# Test 1: Local Kubernetes Cluster & CloudNative-PG Operator Readiness
# ------------------------------------------------------------------------------
test_operator_readiness() {
    echo "  Verifying k3d cluster and CloudNative-PG controller manager..."
    if ! k3d cluster list | grep -q "cnpg-lab"; then
        echo "  Creating local k3d cluster 'cnpg-lab'..."
        k3d cluster create cnpg-lab --servers 1 --agents 0 --wait
    fi

    echo "  Applying CloudNative-PG Operator 1.25.0 release manifests..."
    kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.25.0.yaml >/dev/null 2>&1 || true

    echo "  Waiting for cnpg-controller-manager deployment to become ready..."
    kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=90s

    echo "  CloudNative-PG Operator is running and ready."
    return 0
}
run_test "Kubernetes Cluster & CloudNative-PG Operator Readiness" test_operator_readiness

# ------------------------------------------------------------------------------
# Test 2: MinIO S3 Object Storage & Backup Bucket Setup
# ------------------------------------------------------------------------------
test_s3_storage_setup() {
    echo "  Deploying MinIO S3 and database credentials..."
    kubectl apply -f "$SCRIPT_DIR/manifests/01-minio-s3.yaml"
    kubectl apply -f "$SCRIPT_DIR/manifests/02-secrets.yaml"

    echo "  Waiting for MinIO deployment and bucket creator job..."
    kubectl rollout status deployment/minio -n default --timeout=60s
    kubectl wait --for=condition=complete job/minio-bucket-creator -n default --timeout=60s

    echo "  S3 Object Storage and bucket 'pg-wal-archives' verified."
    return 0
}
run_test "MinIO S3 Object Storage & Backup Bucket Deployment" test_s3_storage_setup

# ------------------------------------------------------------------------------
# Test 3: 3-Instance PostgreSQL Cluster CRD Creation & Healthy State
# ------------------------------------------------------------------------------
test_cluster_deployment() {
    echo "  Applying CloudNative-PG Cluster CRD manifest..."
    kubectl apply -f "$SCRIPT_DIR/manifests/03-cluster.yaml"

    echo "  Waiting for pg-ha-cluster to reach Healthy state (3 ready instances)..."
    kubectl wait --for=condition=Ready cluster.postgresql.cnpg.io/pg-ha-cluster -n default --timeout=150s

    local ready_instances
    ready_instances=$(kubectl get cluster.postgresql.cnpg.io pg-ha-cluster -n default -o jsonpath='{.status.readyInstances}')
    echo "  • Ready Instances: ${ready_instances} / 3"

    if (( ready_instances == 3 )); then
        echo "  3-instance PostgreSQL HA cluster verified."
        return 0
    else
        echo "  Cluster did not reach 3 ready instances."
        return 1
    fi
}
run_test "3-Instance PostgreSQL Cluster CRD Creation & Health Check" test_cluster_deployment

# ------------------------------------------------------------------------------
# Test 4: Initial Schema & Seed Data Ingestion on Primary
# ------------------------------------------------------------------------------
test_seed_data_ingestion() {
    local primary
    primary=$(kubectl get cluster.postgresql.cnpg.io pg-ha-cluster -n default -o jsonpath='{.status.targetPrimary}')
    echo "  Active Primary Pod: ${primary}"

    echo "  Seeding ecommerce_db tables on Primary..."
    kubectl exec "${primary}" -n default -c postgres -- psql -U postgres -d ecommerce_db -q -c "
    CREATE TABLE IF NOT EXISTS customers (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(150) NOT NULL UNIQUE
    );
    CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
        customer_id INT NOT NULL,
        amount NUMERIC(10, 2) NOT NULL,
        status VARCHAR(50) NOT NULL
    );
    INSERT INTO customers (name, email) VALUES
    ('Alice Johnson', 'alice@cnpg.dev'),
    ('Bob Smith', 'bob@cnpg.dev'),
    ('Charlie Brown', 'charlie@cnpg.dev')
    ON CONFLICT DO NOTHING;

    INSERT INTO orders (customer_id, amount, status) VALUES
    (1, 150.00, 'COMPLETED'),
    (2, 450.50, 'COMPLETED'),
    (3, 89.99, 'PENDING');
    "

    local count
    count=$(kubectl exec "${primary}" -n default -c postgres -- psql -U postgres -d ecommerce_db -t -A -c "SELECT COUNT(*) FROM orders;")
    echo "  • Total Orders in Database: ${count}"

    if (( count >= 3 )); then
        echo "  Seed data ingestion verified."
        return 0
    else
        echo "  Failed to seed initial records."
        return 1
    fi
}
run_test "Initial Schema & Seed Data Ingestion on Primary" test_seed_data_ingestion

# ------------------------------------------------------------------------------
# Test 5: Standby Streaming Replication Synchronization Audit
# ------------------------------------------------------------------------------
test_streaming_replication() {
    local primary
    primary=$(kubectl get cluster.postgresql.cnpg.io pg-ha-cluster -n default -o jsonpath='{.status.targetPrimary}')
    echo "  Auditing streaming replication status on Primary (${primary})..."

    local stream_count
    stream_count=$(kubectl exec "${primary}" -n default -c postgres -- psql -U postgres -d ecommerce_db -t -A -c \
        "SELECT COUNT(*) FROM pg_stat_replication WHERE state = 'streaming';")

    echo "  • Active Streaming Standby Replicas: ${stream_count} (Expected: 2)"

    if (( stream_count >= 2 )); then
        echo "  Streaming replication verified across all standby nodes."
        return 0
    else
        echo "  Replication audit failed: only ${stream_count} active streaming replicas."
        return 1
    fi
}
run_test "Standby Streaming Replication Synchronization Audit" test_streaming_replication

# ------------------------------------------------------------------------------
# Test 6: Primary Termination & Automated Standby Promotion (RTO < 10s)
# ------------------------------------------------------------------------------
test_primary_failover() {
    echo "  Executing automated failover test script..."
    "$SCRIPT_DIR/operator_failover_test.sh"

    echo "  Failover and self-healing verified."
    return 0
}
run_test "Primary Termination & Automated Standby Promotion (RTO < 10s)" test_primary_failover

# ------------------------------------------------------------------------------
# Test 7: S3 Physical Backup CRD Execution & Archive Verification
# ------------------------------------------------------------------------------
test_backup_crd() {
    echo "  Applying on-demand S3 Backup CRD..."
    kubectl delete backup.postgresql.cnpg.io/pg-ha-cluster-backup -n default >/dev/null 2>&1 || true
    kubectl apply -f "$SCRIPT_DIR/manifests/04-backup.yaml"

    echo "  Waiting for Backup CRD phase to complete..."
    local retries=25
    local phase=""
    while (( retries > 0 )); do
        phase=$(kubectl get backup.postgresql.cnpg.io pg-ha-cluster-backup -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "completed" ]]; then
            echo "  • Backup Phase: ${phase}"
            echo "  Physical backup to MinIO S3 completed successfully."
            return 0
        fi
        sleep 2
        retries=$((retries - 1))
    done
    echo "  Backup failed or timed out: phase=$phase"
    return 1
}
run_test "S3 Physical Backup CRD Execution & Archive Verification" test_backup_crd

# ------------------------------------------------------------------------------
# Final Test Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CLR_BOLD}======================================================================${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}  📊 CloudNative-PG Operator Test Execution Summary${CLR_RESET}"
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
